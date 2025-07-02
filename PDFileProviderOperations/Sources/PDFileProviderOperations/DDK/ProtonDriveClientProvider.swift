// Copyright (c) 2024 Proton AG
//
// This file is part of Proton Drive.
//
// Proton Drive is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Proton Drive is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Proton Drive. If not, see https://www.gnu.org/licenses/.

import FileProvider
import PDClient
import PDCore
import PDDesktopDevKit
import PDFileProvider
import ProtonCoreNetworking
import ProtonCoreServices
import ProtonCoreLog
import ProtonCoreUtilities

actor ProtonDriveClientProvider {

    private let storage: StorageManager
    private let sessionVault: SessionVault
    private let networking: ProtonCoreServices.APIService
    private let ddkMetadataUpdater: DDKMetadataUpdater
    private let ddkSessionCommunicator: SessionRelatedCommunicatorBetweenMainAppAndExtensions
    private let telemetrySettings: TelemetrySettingRepository
    private let ignoreSslCertificateErrors: Bool

    // We box the reference to protonDriveClient in a WeakReference
    // to allow the access to protonDriveClient in a non-isolated keyMissedCallback.
    // We also wrap the WeakReference in Atomic because we want the access to the underlying instance
    // to be synchronous and serialized, to avoid the race between the key miss callback
    // and protonDriveClient reference change (after new ProtonDriveClient instance creation).
    private let protonDriveClientNonIsolatedAccessor: Atomic<WeakReference<ProtonDriveClient>> = .init(.init(reference: nil))

    private(set) var protonDriveClient: ProtonDriveClient? {
        didSet {
            protonDriveClientNonIsolatedAccessor.mutate { $0.reference = protonDriveClient }
        }
    }

    var volumeID: String? {
        get async {
            let moc = storage.backgroundContext
            return await moc.perform {
                self.storage.volumes(moc: moc).first?.id
            }
        }
    }

    private var isDDKSessionAvailable: Bool {
        sessionVault.isDDKSessionAvailable
    }

    init(storage: StorageManager,
         sessionVault: SessionVault,
         networking: ProtonCoreServices.APIService,
         telemetrySettings: TelemetrySettingRepository,
         ddkMetadataUpdater: DDKMetadataUpdater,
         ddkSessionCommunicator: SessionRelatedCommunicatorBetweenMainAppAndExtensions,
         ignoreSslCertificateErrors: Bool) {
        self.storage = storage
        self.sessionVault = sessionVault
        self.networking = networking
        self.ddkMetadataUpdater = ddkMetadataUpdater
        self.ddkSessionCommunicator = ddkSessionCommunicator
        self.telemetrySettings = telemetrySettings
        self.ignoreSslCertificateErrors = ignoreSslCertificateErrors
    }

    func createProtonClientIfNeeded() async {
        if protonDriveClient == nil {
            protonDriveClient = await createProtonClient()
        }
    }

    func renewProtonApiSession(credential: Credential) async -> String? {
        let newSession: ProtonApiSession?
        let sessionMessage: String
        if let oldSession = protonDriveClient?.session {
            sessionMessage = "renewing old session "
            let sessionRenewRequest = SessionRenewRequest.with {
                $0.sessionID.value = credential.UID
                $0.accessToken = credential.accessToken
                $0.refreshToken = credential.refreshToken
                $0.scopes = credential.scopes
                $0.isWaitingForSecondFactorCode = false
                $0.passwordMode = .single
            }

            newSession = ProtonApiSession.renewSession(
                oldSession: oldSession,
                sessionRenewRequest: sessionRenewRequest,
                onTokensRefreshed: { [weak self] tokens in
                    guard let self else {
                        Log.warning("Failed to update storage with the refreshed tokens because lack of self",
                                    domain: .fileProvider)
                        return
                    }
                    Task {
                        await self.sessionVault.updateDDKSessionTokens(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
                    }
                }
            )
        } else {
            sessionMessage = "creation of new session "
            newSession = await createProtonApiSession()
        }
        guard let session = newSession else {
            return sessionMessage + "failed"
        }

        var observabilityService: ObservabilityService?
        if telemetrySettings.isTelemetryEnabled() {
            observabilityService = createObservabilityService(using: session)
            guard observabilityService != nil else {
                return sessionMessage + "succeeded, but observability creation failed"
            }
        }

        guard let client = await createProtonDriveClient(session: session, observability: observabilityService) else {
            return sessionMessage + "and observability creation succeeded, but proton drive client creation failed"
        }
        protonDriveClient = client
        Log.info("\(sessionMessage)succeeded, observability and client recreated", domain: .fileProvider)
        return nil // no error message because the renew succeeded
    }

    func flushObservability() async {
        do {
            try await protonDriveClient?.observabilityService?.flush(cancellationTokenSource: CancellationTokenSource())
        } catch {
            Log.warning("Observability flush failed: \(error)", domain: .fileProvider)
        }
    }

    // MARK: - Object creation

    private func createProtonClient() async -> ProtonDriveClient? {
        guard let session = await createProtonApiSession() else {
            Log.warning("CreateProtonDriveClient failed because session cannot be created", domain: .fileProvider)
            return nil
        }

        var observabilityService: ObservabilityService?
        if telemetrySettings.isTelemetryEnabled() {
            observabilityService = createObservabilityService(using: session)
            guard observabilityService != nil else {
                Log.warning("CreateProtonDriveClient failed because observability cannot be created", domain: .fileProvider)
                return nil
            }
        }

        guard let client = await createProtonDriveClient(session: session, observability: observabilityService) else {
            Log.warning("CreateProtonDriveClient failed because client cannot be created", domain: .fileProvider)
            return nil
        }
        Log.info("CreateProtonDriveClient succeeded", domain: .fileProvider)
        return client
    }

    private func createProtonApiSession() async -> ProtonApiSession? {
        let currentlyUsedURL = networking.dohInterface.getCurrentlyUsedHostUrl()
        let baseUrl = currentlyUsedURL.hasSuffix("/") ? currentlyUsedURL : currentlyUsedURL + "/"

        guard isDDKSessionAvailable else {
            await ddkSessionCommunicator.askMainAppToProvideNewChildSession()
            return nil
        }

        guard let ddkCredential = sessionVault.ddkCredential,
              let key = sessionVault.getUser()?.keys.first,
              let passphrase = try? sessionVault.getUserPassphrase()
        else {
            return nil
        }

        let credentials = ClientCredential(ddkCredential)

        let appVersion = networking.serviceDelegate?.appVersion ?? "other@0.1.0+dotnet-sdk-cli"
        let userAgent = networking.serviceDelegate?.userAgent ?? "ProtonDrive/macOS (15.0)"

        let sessionResumeRequest = SessionResumeRequest.with {
            $0.options.baseURL = baseUrl
            $0.options.ignoreSslCertificateErrors = (baseUrl.contains("proton.black") || ignoreSslCertificateErrors)
            $0.options.disableTlsPinning = false
            $0.options.appVersion = appVersion
            $0.options.userAgent = userAgent
            $0.options.loggerProviderHandle = Int64(LoggerProvider.handle)

            $0.sessionID.value = credentials.UID
            $0.username = credentials.userName
            $0.userID.value = credentials.userID
            $0.accessToken = credentials.accessToken
            $0.refreshToken = credentials.refreshToken
            $0.scopes = credentials.scope
            $0.isWaitingForSecondFactorCode = false
            $0.passwordMode = .single
        }

        let protonApiSession = ProtonApiSession.resumeSession(
            sessionResumeRequest: sessionResumeRequest
        ) { [weak self] responseBodyResponse in
            guard let self else {
                Log.error("Parsing responseBodyResponse failed", domain: .ddk, context: LogContext("\(responseBodyResponse.operationID.type) response body from \(responseBodyResponse.operationID.timestamp) for \(responseBodyResponse.method) \(responseBodyResponse.url) failed because there is no self"))
                return
            }
            self.ddkMetadataUpdater.parseResponseBodyResponse(responseBodyResponse)
        } onKeyCacheMiss: { [weak self] keyCacheMiss in
            guard let self else {
                Log.warning("Failed to register a key \(keyCacheMiss) because lack of self",
                            domain: .fileProvider)
                return false
            }
            let keyRegisteredSuccessfully = DDKKeyRegistration.processKeyCacheMiss(
                keyCacheMiss: keyCacheMiss,
                protonDriveClientAccessor: protonDriveClientNonIsolatedAccessor,
                storage: self.storage
            )
            return keyRegisteredSuccessfully
        } onTokensRefreshed: { [weak self] tokens in
            guard let self else {
                Log.warning("Failed to update storage with the refreshed tokens because lack of self",
                            domain: .fileProvider)
                return
            }
            Task {
                await self.sessionVault.updateDDKSessionTokens(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
            }
        }

        guard let protonApiSession else { return nil }

        let wasUseKeyRegisteredSuccessfully = DDKKeyRegistration.registerUserKey(key, passphrase, protonApiSession)
        guard wasUseKeyRegisteredSuccessfully else {
            Log.error("Registering user key in DDK failed. File Provider cannot work without user key being registered", domain: .fileProvider)
            return nil
        }

        await DDKKeyRegistration.registerAddressKeys(protonApiSession, sessionVault)
        return protonApiSession
    }

    private func createObservabilityService(
        using protonApiSession: ProtonApiSession?
    ) -> ObservabilityService? {
        protonApiSession.flatMap(ObservabilityService.init(session:))
    }

    private func createProtonDriveClient(
        session: ProtonApiSessionProtocol?,
        observability: ObservabilityServiceProtocol?
    ) async -> ProtonDriveClient? {
        var clientID = sessionVault.getUploadClientUID()
        // this should never happen, but let's cover this just in case.
        // getUploadClientUID() should report error to Sentry already
        if clientID.isEmpty { clientID = UUID().uuidString }
        guard let session else {
            return nil
        }
        let request = ProtonDriveClientCreateRequest.with {
            $0.clientID.value = clientID
        }
        let client = ProtonDriveClient(session: session, observability: observability, clientCreationRequest: request)
        do {
            let (share, _) = try storage.getMainShareAndVolume(in: storage.backgroundContext)
            let wasShareKeyRegistrationSuccessful = try DDKKeyRegistration.registerShareKey(share, WeakReference(reference: client))
            guard wasShareKeyRegistrationSuccessful else {
                Log.warning("Failed to register a share key because registerShareKey failed within DDK",
                            domain: .fileProvider)
                return client
            }
        } catch {
            Log.warning("Failed to register a share key because of error \(error.localizedDescription)",
                        domain: .fileProvider)
            return client
        }
        return client
    }
}
