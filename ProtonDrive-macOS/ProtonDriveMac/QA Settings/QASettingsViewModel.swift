// Copyright (c) 2023 Proton AG
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

#if HAS_QA_FEATURES

import AppKit
import Combine
import PDCore
import FileProvider

struct QASettingsConstants {
    static let shouldUpdateEvenOnDebugBuild = "shouldUpdateEvenOnDebugBuild"
    static let shouldUpdateEvenOnTestFlight = "shouldUpdateEvenOnTestFlight"
    static let updateChannel = "updateChannel"
    static let shouldObfuscateDumpsStorage = "shouldObfuscateDumpsStorage"
    static let disconnectDomainOnSignOut = "disconnectDomainOnSignOut"
    static let driveDDKEnabled = "driveDDKEnabled"
    static let newTrayAppMenuEnabled = "newTrayAppMenuEnabled"
    static let globalProgressStatusMenuEnabled = "globalProgressStatusMenuEnabled"
}

protocol EventLoopManager: AnyObject {
    var shouldFetchEvents: Bool? { get set }
}

extension Tower: EventLoopManager {}

protocol SignoutManager {
    func signOutAsync() async
}

class QASettingsViewModel: ObservableObject {
    @Published var environment: String
    @Published var domainDisconnectionReason: String = "Hello!"
    @Published var shouldDisconnectTemporarily: Bool = false
    @Published var dumperIsBusy: Bool = false
    @Published var dumperError: String = ""

#if HAS_BUILTIN_UPDATER
    @Published var shouldUpdateEvenOnDebugBuild: Bool = false {
        didSet { shouldUpdateEvenOnDebugBuildStorage = shouldUpdateEvenOnDebugBuild }
    }
    @Published var shouldUpdateEvenOnTestFlight: Bool = false {
        didSet { shouldUpdateEvenOnTestFlightStorage = shouldUpdateEvenOnTestFlight }
    }
    @Published var updateChannel: String = AppUpdateChannel.stable.rawValue {
        didSet { updateChannelStorage = updateChannel }
    }
    @Published var updateMessage: String = ""
    @SettingsStorage(QASettingsConstants.shouldUpdateEvenOnDebugBuild) var shouldUpdateEvenOnDebugBuildStorage: Bool?
    @SettingsStorage(QASettingsConstants.shouldUpdateEvenOnTestFlight) var shouldUpdateEvenOnTestFlightStorage: Bool?
    @SettingsStorage(QASettingsConstants.updateChannel) var updateChannelStorage: String?
#endif
    
    @Published var shouldFetchEvents: Bool = true {
        didSet {
            guard let eventLoopManager else { return }
            if eventLoopManager.shouldFetchEvents != shouldFetchEvents {
                eventLoopManager.shouldFetchEvents = shouldFetchEvents
            }
        }
    }
    
    @Published var shouldObfuscateDumps: Bool = false {
        didSet { shouldObfuscateDumpsStorage = shouldObfuscateDumps }
    }
    
    @Published var enablePostMigrationCleanup: Bool = false {
        didSet { requiresPostMigrationCleanup = enablePostMigrationCleanup }
    }
    @SettingsStorage(QASettingsConstants.shouldObfuscateDumpsStorage) var shouldObfuscateDumpsStorage: Bool?
    @SettingsStorage("requiresPostMigrationStep") private var requiresPostMigrationCleanup: Bool?
    
    enum FeatureFlagOptions: String, CaseIterable {
        case useFF
        case enabled
        case disabled
        
        var toBool: Bool? {
            switch self {
            case .useFF: return nil
            case .enabled: return true
            case .disabled: return false
            }
        }
        
        init(bool: Bool?) {
            switch bool {
            case nil: self = .useFF
            case true?: self = .enabled
            case false?: self = .disabled
            }
        }
    }
    var domainReconnectionFeatureFlagValue: Bool {
        featureFlags?.isEnabled(flag: .domainReconnectionEnabled) ?? false
    }
    @Published var domainDisconnected: Bool = false
    @Published var disconnectDomainOnSignOut: String = FeatureFlagOptions.useFF.rawValue {
        didSet { disconnectDomainOnSignOutStorage = FeatureFlagOptions(rawValue: disconnectDomainOnSignOut)?.toBool }
    }
    @SettingsStorage(QASettingsConstants.disconnectDomainOnSignOut) var disconnectDomainOnSignOutStorage: Bool?

    var driveDDKEnabledFeatureFlagValue: Bool {
        featureFlags?.isEnabled(flag: .driveDDKEnabled) ?? false
    }
    @Published var driveDDKEnabled: String = FeatureFlagOptions.useFF.rawValue {
        didSet { driveDDKEnabledStorage = FeatureFlagOptions(rawValue: driveDDKEnabled)?.toBool }
    }
    @SettingsStorage(QASettingsConstants.driveDDKEnabled) var driveDDKEnabledStorage: Bool?
    
    var newTrayAppMenuEnabledFeatureFlagValue: Bool {
        featureFlags?.isEnabled(flag: .newTrayAppMenuEnabled) ?? false
    }
    @Published var newTrayAppMenuEnabled: String = FeatureFlagOptions.useFF.rawValue {
        didSet { newTrayAppMenuEnabledStorage = FeatureFlagOptions(rawValue: newTrayAppMenuEnabled)?.toBool }
    }
    @SettingsStorage(QASettingsConstants.newTrayAppMenuEnabled) var newTrayAppMenuEnabledStorage: Bool?

    let parentSessionUID: String
    let childSessionUID: String
    let userID: String
    let clearCredentials: () -> Void
    
    private let dumper: Dumper?
    private let eventLoopManager: EventLoopManager?
    private let featureFlags: PDCore.FeatureFlagsRepository?
    private let signoutManager: SignoutManager?
    private let mainKeyProvider: MainKeyProvider
    private let metadataStorage: StorageManager?
    private let eventsStorage: EventStorageManager?

    let applicationEventObserver: ApplicationEventObserver
    let userActions: UserActions
    
    init(signoutManager: SignoutManager?,
         sessionStore: SessionVault,
         mainKeyProvider: MainKeyProvider,
         appUpdateService: AppUpdateServiceProtocol?,
         eventLoopManager: EventLoopManager?,
         featureFlags: PDCore.FeatureFlagsRepository?,
         dumperDependencies: DumperDependencies?,
         applicationEventObserver: ApplicationEventObserver,
         userActions: UserActions,
         metadataStorage: StorageManager?,
         eventsStorage: EventStorageManager?
    ) {
        let suite = Constants.appGroup
        self._requiresPostMigrationCleanup.configure(with: suite)
        self._disconnectDomainOnSignOutStorage.configure(with: suite)
        self._driveDDKEnabledStorage.configure(with: suite)
        self._newTrayAppMenuEnabledStorage.configure(with: suite)

        self.dumper = dumperDependencies.map(Dumper.init)
        self.environment = Constants.appGroup.userDefaults.string(forKey: Constants.SettingsBundleKeys.host.rawValue) ?? ""
        self.signoutManager = signoutManager
        self.clearCredentials = {
            sessionStore.signOut()
            NSRunningApplication.current.terminate()
        }
        self.mainKeyProvider = mainKeyProvider
        self.parentSessionUID = sessionStore.parentSessionUID ?? "(no parent session available)"
        self.childSessionUID = sessionStore.childSessionUID ?? "(no child session available)"
        self.userID = sessionStore.getAccountInfo()?.userIdentifier ?? "(no user identifier available)"
        self.eventLoopManager = eventLoopManager
        self.featureFlags = featureFlags
        self.shouldFetchEvents = eventLoopManager?.shouldFetchEvents ?? true

        self.applicationEventObserver = applicationEventObserver
        self.userActions = userActions
        
        self.metadataStorage = metadataStorage
        self.eventsStorage = eventsStorage

        self.shouldObfuscateDumps = shouldObfuscateDumpsStorage ?? false
        self.enablePostMigrationCleanup = requiresPostMigrationCleanup ?? false
        self.disconnectDomainOnSignOut = FeatureFlagOptions(bool: disconnectDomainOnSignOutStorage).rawValue
        self.driveDDKEnabled = FeatureFlagOptions(bool: driveDDKEnabledStorage).rawValue
        self.newTrayAppMenuEnabled = FeatureFlagOptions(bool: newTrayAppMenuEnabledStorage).rawValue

#if HAS_BUILTIN_UPDATER
        self.shouldUpdateEvenOnDebugBuild = shouldUpdateEvenOnDebugBuildStorage ?? false
        self.shouldUpdateEvenOnTestFlight = shouldUpdateEvenOnTestFlightStorage ?? false
        self.updateChannel = updateChannelStorage ?? AppUpdateChannel.stable.rawValue
        if let appUpdateService {
            self.updateMessage = """
                             Last update check: \(appUpdateService.updater.lastUpdateCheckDate.map(String.init) ?? "never")
                             Update check interval: \(appUpdateService.updater.updateCheckInterval)
                             """
        }
#endif
    }

    func confirmEnvironmentChange() {
        Task { [weak self] in
            guard let self else { return }
            Constants.appGroup.userDefaults.set(self.environment, forKey: Constants.SettingsBundleKeys.host.rawValue)
            await self.signoutManager?.signOutAsync()
            _ = await MainActor.run {
                exit(0)
            }
        }
    }
    
    func confirmDomainDisconnectionReasonChange() {
        let reason = domainDisconnectionReason
        let temporary = shouldDisconnectTemporarily
        Task {
            do {
                let domains = try await NSFileProviderManager.domains()
                try await domains.forEach { domain in
                    guard let fileProviderManager = NSFileProviderManager(for: domain) else {
                        assertionFailure("Could not create fileProviderManager, investigate!")
                        return
                    }
                    if !domain.isDisconnected {
                        for i in 0...4 {
                            try await fileProviderManager.disconnect(
                                reason: "Some previous disconnection reason, will update in \(5 - i) seconds",
                                options: .temporary
                            )
                            try await Task.sleep(for: .seconds(1))
                        }
                    }
                    try await fileProviderManager.disconnect(
                        reason: reason, options: temporary ? .temporary : []
                    )
                }
            } catch {
                assertionFailure("Could not get domains, investigate! Error is \(error)")
            }
        }
    }

    func sendTestEventToSentry(level: LogLevel) {
        let originalLogger = Log.logger
        // Temporarily replace logger to test Sentry events sending
        Log.logger = ProductionLogger()
        let error = NSError(domain: "MACOS APP SENTRY TESTING", code: 0, localizedDescription: "Test from macOS app")
        Log.error("issue title from app", error: error, domain: .logs, context: LogContext("context string"))

        switch level {
        case .error: Log.error("Test from macOS app", error: error, domain: .application, sendToSentryIfPossible: true)
        case .warning: Log.warning(error.localizedDescription, domain: .application, sendToSentryIfPossible: true)
        case .info: Log.info(error.localizedDescription, domain: .application, sendToSentryIfPossible: true)
        case .debug: Log.debug(error.localizedDescription, domain: .application, sendToSentryIfPossible: true)
        case .trace: Log.trace(error.localizedDescription)
        }
        // Restore original logger after the test
        Log.logger = originalLogger
    }

    func sentTestCrashToSentry() {
        fatalError("macOS app: Forced crash to test Sentry crash reporting")
    }

    func sendNotificationToDisconnectDomain() {
        let userInfo = ["domainDisconnected": domainDisconnected ]
        NotificationCenter.default.post(name: .fileProviderDomainStateDidChange, object: nil, userInfo: userInfo)
        domainDisconnected = true
    }

    func sendNotificationToReconnectDomain() {
        let userInfo = ["domainDisconnected": domainDisconnected ]
        NotificationCenter.default.post(name: .fileProviderDomainStateDidChange, object: nil, userInfo: userInfo)
        domainDisconnected = false
    }

    func tellFileProviderToTestSendingErrorEventToTestSentry() {
        DarwinNotificationCenter.shared.postNotification(.SendErrorEventToTestSentry)
    }

    func tellFileProviderToTestSendingCrashToSentry() {
        DarwinNotificationCenter.shared.postNotification(.DoCrashToTestSentry)
    }
    
    func corruptMetadataAndEventDBs() {
        guard let mmoc = metadataStorage?.newBackgroundContext(), let emoc = eventsStorage?.makeNewBackgroundContext() else { return }
        do {
            try mmoc.performAndWait {
                let allNodes = try mmoc.fetch(Node.fetchRequest())
                allNodes.forEach {
                    $0.name = "💣"
                    $0.nodeKey = "💣"
                }
                try mmoc.save()
            }
            try emoc.performAndWait {
                let allEvents = try emoc.fetch(PersistedEvent.fetchRequest())
                allEvents.forEach {
                    $0.contents = "💣".data(using: .utf8)
                }
                try emoc.save()
            }
        } catch {
            Log.debug("\(#function) failed: \(error.localizedDescription)", domain: .application)
        }
    }
    
    func wipeMainKey() {
        requiresPostMigrationCleanup = true
        try? mainKeyProvider.wipeMainKeyOrError()
        NSRunningApplication.current.terminate()
    }
    
    func dumpDBReplica() {
        Task { @MainActor in
            dumperError = ""
            dumperIsBusy = true
            defer { dumperIsBusy = false }
            
            try await dumper?.dumpDBReplica()
        } catch: {
            dumperError = $0.localizedDescription
        }
    }
    
    func dumpFSReplica() {
        Task { @MainActor in
            dumperError = ""
            dumperIsBusy = true
            defer { dumperIsBusy = false }
            
            try await dumper?.dumpFSReplica()
        } catch: {
            dumperError = $0.localizedDescription
        }
    }
    
    func dumpCloudReplica() {
        Task { @MainActor in
            dumperError = ""
            dumperIsBusy = true
            defer { dumperIsBusy = false }
            
            do {
                try await dumper?.dumpCloudReplica()
            }
        } catch: { @MainActor in
            dumperError = $0.localizedDescription
        }
    }
}

extension Notification.Name {
    static var fileProviderDomainStateDidChange = Notification.Name(rawValue: "ch.protonmail.drive.fileProviderDomainStateDidChange")
}

#endif
