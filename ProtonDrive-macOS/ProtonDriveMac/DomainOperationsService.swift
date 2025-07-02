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
import Combine
import PDCore
import PDFileProvider

#if os(macOS)

public protocol AccountInfoProvider {
    var allAddresses: [String] { get }
    func getAccountInfo() -> AccountInfo?
}

extension SessionVault: AccountInfoProvider {}

public protocol FileProviderManagerFactory {
    associatedtype FileProviderManager: FileProviderManagerProtocol
    var type: FileProviderManager.Type { get }
    func create(for domain: NSFileProviderDomain) -> FileProviderManager?
}

final class SystemFileProviderManagerFactory: FileProviderManagerFactory {
    var type: NSFileProviderManager.Type { NSFileProviderManager.self }
    
    func create(for domain: NSFileProviderDomain) -> NSFileProviderManager? {
        NSFileProviderManager(for: domain)
    }
}

public protocol FileProviderManagerProtocol {
    func signalEnumerator(for containerItemIdentifier: NSFileProviderItemIdentifier) async throws
    func signalErrorResolved(_ error: any Error) async throws
    func getUserVisibleURL(for itemIdentifier: NSFileProviderItemIdentifier) async throws -> URL
    static func add(_ domain: NSFileProviderDomain) async throws
    static func remove(_ domain: NSFileProviderDomain, mode: NSFileProviderManager.DomainRemovalMode) async throws -> URL?
    static func domains() async throws -> [NSFileProviderDomain]
    func disconnect(reason localizedReason: String, options: NSFileProviderManager.DisconnectionOptions) async throws
    func reconnect() async throws
}

extension NSFileProviderManager: FileProviderManagerProtocol {}

public final class DomainOperationsService: DomainOperationsServiceProtocol {

    @SettingsStorage("domainDisconnectedReasonCacheReset") public var cacheReset: Bool?
    
    #if HAS_QA_FEATURES
    @SettingsStorage(QASettingsConstants.disconnectDomainOnSignOut) private var disconnectDomainOnSignOut: Bool?
    #endif
    
    var hasDomainReconnectionCapability: Bool {
        assert(featureFlags() != nil, "Feature flags should be available at this point")
        let domainReconnectionEnabled = featureFlags()?.isEnabled(flag: .domainReconnectionEnabled) ?? false
        #if HAS_QA_FEATURES
        let shouldDisconnect = self.disconnectDomainOnSignOut ?? domainReconnectionEnabled
        #else
        let shouldDisconnect = domainReconnectionEnabled
        #endif
        return shouldDisconnect
    }
    
    private let offlineReason = "🛜 Your internet connection seems to be offline."
    private let pauseReason = "These files will not be synced while Proton Drive is paused."
    private let fullResyncReason = "Full resync in progress..."
    
    private let accountInfoProvider: AccountInfoProvider
    private let featureFlags: () -> PDCore.FeatureFlagsRepository?
    private let fileProviderManagerFactory: any FileProviderManagerFactory
    private let assertionProvider: any AssertionProvider
    
    #if HAS_QA_FEATURES
    private(set) var fileProviderDomain: NSFileProviderDomain?
    #else
    private var fileProviderDomain: NSFileProviderDomain?
    #endif
    private var fileManagerForDomain: FileProviderManagerProtocol? {
        fileProviderDomain.flatMap(fileProviderManagerFactory.create(for:))
    }
    
    init(accountInfoProvider: AccountInfoProvider,
         featureFlags: @escaping () -> PDCore.FeatureFlagsRepository?,
         fileProviderManagerFactory: any FileProviderManagerFactory,
         assertionProvider: AssertionProvider = SystemAssertionProvider.instance) {
        self.accountInfoProvider = accountInfoProvider
        self.featureFlags = featureFlags
        self.fileProviderManagerFactory = fileProviderManagerFactory
        self.assertionProvider = assertionProvider
        _cacheReset.configure(with: Constants.appGroup)
        #if HAS_QA_FEATURES
        _disconnectDomainOnSignOut.configure(with: Constants.appGroup)
        #endif
    }
    
    // MARK: Public API — DomainOperationsServiceProtocol implementation
    
    public var cacheCleanupStrategy: PDCore.CacheCleanupStrategy {
        hasDomainReconnectionCapability ? .doNotCleanAnything : .cleanEverything
    }
    
    public func tearDownConnectionToAllDomains() async throws {
        if hasDomainReconnectionCapability {
            #if HAS_QA_FEATURES
            let reason = "User signed out by disconnecting domain"
            #else
            let reason = ""
            #endif
            try await disconnectDomains(reason: reason)
        } else {
            try await removeAllDomains()
        }
    }
    
    public func signalEnumerator() async throws {
        guard let fileManagerForDomain else { throw NSFileProviderError(.providerNotFound) }
        try await signalEnumeratorWithRetry(fileManager: fileManagerForDomain)
    }

    public func removeAllDomains() async throws {
        let domains = try await getDomainsWithRetry()

        var finalError: DomainOperationErrors?
        try await domains.forEach { domain in
            do {
                try await disconnectDomainWithRetry(
                    domain: domain, reason: "Proton Drive location preparing for removal", options: []
                )
            } catch {
                // even if we fail to disconnect, we still try removing, hence the error is only logged
                Log.error(error: error, domain: .fileProvider)
            }

            do {
                try await removeDomainWithRetry(domain: domain)
            } catch let error as DomainOperationErrors {
                Log.error(error: error, domain: .fileProvider)
                finalError = error
            }
        }

        if let finalError {
            throw finalError
        }
    }
    
    public func groupContainerMigrationStarted() async throws {
        try await disconnectDomain(reason: "One-time migration for Sequoia")
    }

    // MARK: - Resolving errors

    func cleanUpErrors() {
        Task {
            func tryResolving(error: any Error) async {
                do {
                    try await signalErrorResolved(error)
                } catch {
                    Log.error("signalErrorResolved failed", error: error, domain: .fileProvider)
                }
            }
            await tryResolving(error: NSFileProviderError(.notAuthenticated))
            await tryResolving(error: NSFileProviderError(.insufficientQuota))
            await tryResolving(error: NSFileProviderError(.serverUnreachable))
            await tryResolving(error: NSFileProviderError(.cannotSynchronize))
        }
    }

    private func signalErrorResolved(_ error: any Error) async throws {
        guard let fileManagerForDomain else { throw NSFileProviderError(.providerNotFound) }

        try await fileManagerForDomain.signalErrorResolved(error)
    }

    // MARK: - Internal API
    
    func identifyDomain() async throws {
        try await identifyDomainWithRetry()
    }
    
    func setUpDomain() async throws {
        if hasDomainReconnectionCapability {
            try await connectDomain()
        } else {
            try await addNewFileProvider()
        }
    }
    
    func connectDomain() async throws {
        guard let domain = fileProviderDomain else {
            // identify domain
            try await identifyDomainWithRetry()
            // retry
            try await connectDomain()
            return
        }
        
        let userDomains = try await removeDomains(otherThan: domain)
        
        if !userDomains.isEmpty {
            try await reconnectDomainWithRetry(domain: domain)
        } else {
            try await addDomainWithRetry(domain)
            
            cacheReset = false
            // IMPORTANT: there was `guard!domain.isDisconnected else { return }` check before
            // but we've found out we shouldn't rely on this property.
            // It's not updated after the initial domain fetching.
            // We could make a `getDomain` call before checking it here, but I believe it's unnecessary.
            
            do {
                try await reconnectDomainWithRetry(domain: domain)
            } catch {
                // Domain not reconnecting is a user-recoverable situation (pause/resume), so let's only log the error
                Log.error("Failed to reconnect domain", error: error, domain: .fileProvider)
            }
        }
    }
    
    func domainExists() async throws -> Bool {
        guard let domain = fileProviderDomain else { return false }
        let domains = try await self.getDomainsWithRetry()
        let userDomains = domains.filter { $0.identifier == domain.identifier }
        return !userDomains.isEmpty
    }
    
    func domainWasPaused() async throws {
        try await disconnectDomain(reason: pauseReason)
    }
    
    func performingFullResync() async throws {
        try await disconnectDomain(reason: fullResyncReason)
    }
    
    func domainWasResumed() async throws {
        try await reconnectDomain()
    }
    
    func networkConnectionLost() async throws {
        try await disconnectDomain(reason: offlineReason)
    }
    
    func disconnectDomainsDuringMainKeyCleanup() async throws {
        try await disconnectDomains(
            reason: "Attempting to reconnect. This may take a few minutes. Please do not quit the application"
        )
    }
    
    #if HAS_QA_FEATURES
    func disconnectDomainsForQA(reason: (NSFileProviderDomain?) -> String) async throws {
        try await disconnectDomains(reason: reason(fileProviderDomain))
    }
    #endif
    
    func disconnectDomainBeforeAppClosing() async throws {
        try await disconnectDomain(reason: "Proton Drive needs to be running in order to sync these files.")
    }
    
    func dumpingStarted() async throws {
        try await disconnectDomain(reason: "Dumping FS...")
    }
    
    func cleanAfterDumping() {
        if cacheReset != true {
            Task {
                try await reconnectDomain()
            }
        }
    }
    
    func getUserVisibleURLForRoot() async throws -> URL {
        guard let fileManagerForDomain else { throw NSFileProviderError(.providerNotFound) }
        return try await userVisibleURLForRootWithRetry(manager: fileManagerForDomain)
    }
    
    // MARK: - Private API
    
    private func domainForCurrentlyLoggedInUser() async throws -> NSFileProviderDomain? {
        let currentUserDomain = currentUserDomain()
        let existingDomains = try await getDomainsWithRetry()
        
        guard !existingDomains.isEmpty else {
            return currentUserDomain
        }
    
        if let currentUserDomain, !currentUserDomain.identifier.rawValue.isEmpty,
        let foundDomain = existingDomains.first(where: { $0.identifier == currentUserDomain.identifier }) {
            return foundDomain
        }
    
        for addressDomain in addressDomains() {
            if let foundDomain = existingDomains.first(where: { $0.identifier == addressDomain.identifier }) {
                return foundDomain
            }
        }
        return currentUserDomain
    }

    private func currentUserDomain() -> NSFileProviderDomain? {
        guard let accountInfo = accountInfoProvider.getAccountInfo() else {
            let message = "Must have valid account info to create FileProviderDomain"
            assertionProvider.assertionFailure(message)
            Log.error(message, domain: .fileProvider)
            return nil
        }
        return DomainFactory.createDomain(identifier: .init(accountInfo.userIdentifier), displayName: "\(accountInfo.email)-folder")
    }

    private func addressDomains() -> [NSFileProviderDomain] {
        accountInfoProvider.allAddresses
            .map { DomainFactory.createDomain(identifier: .init($0), displayName: $0) }
    }
    
    private func addNewFileProvider() async throws {
        
        guard let domain = fileProviderDomain else {
            // identify domain
            try await identifyDomainWithRetry()
            // retry
            try await addNewFileProvider()
            return
        }

        // for the cleanup, we try removing the old domains before adding a new one
        // however, if this cleanup fails, we do continue
        do {
            _ = try await removeDomains(otherThan: domain)
        } catch {
            Log.error(error: error, domain: .fileProvider)
        }

        do {
            try await addDomainWithRetry(domain)
            // if we've added a new domain, we don't need a cache reset anymore
        } catch {
            Log.error(error: error, domain: .fileProvider)
            throw error
        }
        
        cacheReset = false
        // IMPORTANT: there was `guard !domain.isDisconnected else { return }` check before
        // but we've found out we shouldn't rely on this property.
        // It's not updated after the initial domain fetching.
        // We could make a `getDomain` call before checking it here, but I believe it's unnecessary.
        do {
            try await reconnectDomainWithRetry(domain: domain)
        } catch {
            // Domain not reconnecting is a user-recoverable situation (pause/resume), so let's only log the error
            Log.error(error: error, domain: .fileProvider)
        }
    }
    
    private func reconnectDomain() async throws {
        // do not reconnect if we're recreating the cache
        guard cacheReset != true else { return }
        
        guard let fileProviderDomain else {
            // identify domain
            try await identifyDomainWithRetry()
            // retry
            try await reconnectDomain()
            return
        }
        
        do {
            try await reconnectDomainWithRetry(domain: fileProviderDomain)
        } catch {
            Log.error(error: error, domain: .fileProvider)
            throw error
        }
    }
    
    private func removeDomains(otherThan domain: NSFileProviderDomain) async throws -> [NSFileProviderDomain] {
        let domains = try await getDomainsWithRetry()
        
        let userDomains = domains.filter { $0.identifier == domain.identifier }
        let oldDomains = domains.filter { $0.identifier != domain.identifier }
        
        var finalError: DomainOperationErrors?
        for oldDomain in oldDomains {
            do {
                try await removeDomainWithRetry(domain: oldDomain)
            } catch let error as DomainOperationErrors {
                Log.error(error: error, domain: .fileProvider)
                finalError = error
            }
        }
        if let finalError {
            throw finalError
        }
        return userDomains
    }
    
    private func disconnectDomain(reason: String) async throws {
        guard let domain = fileProviderDomain else {
            Log.error("Failed to disconnect domain due to failed manager creation", domain: .fileManager)
            return
        }

        try await disconnect(domain: domain, reason: reason)
    }

    private func disconnectDomains(reason: String) async throws {
        // set the flag informing that the cache reset has started
        cacheReset = true
        let domains = try await getDomainsWithRetry()
        for domain in domains {
            try await disconnect(domain: domain, reason: reason)
        }
    }
    
    private func disconnect(domain: NSFileProviderDomain, reason: String) async throws {
        // IMPORTANT: there was `guard !domain.isDisconnected else { return }` check before
        // but we've found out we shouldn't rely on this property.
        // It's not updated after the initial domain fetching.
        // We could make a `getDomain` call before checking it here, but I believe it's unnecessary.

        do {
            try await disconnectDomainWithRetry(domain: domain, reason: reason, options: [.temporary])
        } catch {
            Log.error(error: error, domain: .fileProvider)
            throw error
        }
    }
}

// MARK: - Domain operations with retry

extension DomainOperationsService {
    
    private func addDomainWithRetry(_ domain: NSFileProviderDomain) async throws {
        Log.debug("Adding domain \(domain.displayName)", domain: .fileProvider)
        try await Self.performWithRetryOnFileProviderError(
            retryCounter: 6,
            retryInterval: .seconds(5),
            successMessage: { "Signal enumerator succeeded after retry: \($0)" },
            errorBlock: { error, _ in DomainOperationErrors.addDomainFailed(error) },
            operation: { [weak self] in
                guard let self else { return }
                do {
                    // Amend possibly-existing domain to not support syncing trash
                    domain.supportsSyncingTrash = false
                    try await self.fileProviderManagerFactory.type.add(domain)
                } catch {
                    // We are ignoring the NSFileWriteFileExistsError,
                    // because documentation of NSFileProviderManager.add method states it is returned
                    // when the domain already exists on the file system. We believe we can just continue in that case.
                    if (error as NSError).domain == NSCocoaErrorDomain,
                       (error as NSError).code == NSFileWriteFileExistsError {
                        Log.error("NSFileProviderManager.add call failed with NSFileWriteFileExistsError", domain: .fileProvider)
                        return
                    }
                    // otherwise, we don't ignore the error
                    throw error
                }
            }
        )
        Log.debug("Added domain \(domain.displayName)", domain: .fileProvider)
    }
    
    private func removeDomainWithRetry(domain: NSFileProviderDomain) async throws {
        Log.debug("Removing domain \(domain.displayName)", domain: .fileProvider)
        try await Self.performWithRetryOnFileProviderError(
            retryCounter: 3,
            retryInterval: .seconds(5),
            successMessage: { "Domain removal succeded after retry \($0)" },
            errorBlock: { error, _ in DomainOperationErrors.removeDomainFailed(error) },
            operation: { [weak self] in
                guard let self else { return }
                _ = try await self.fileProviderManagerFactory.type.remove(domain, mode: .preserveDownloadedUserData)
            }
        )
        Log.debug("Removed domain \(domain.displayName)", domain: .fileProvider)
    }
    
    private func reconnectDomainWithRetry(domain: NSFileProviderDomain) async throws {
        guard let fileManager = fileProviderManagerFactory.create(for: domain) else {
            Log.error("Failed to disconnect domain due to failed manager creation", domain: .fileManager)
            return
        }
        Log.debug("Reconnecting domain \(domain.displayName)", domain: .fileProvider)
        try await Self.performWithRetryOnFileProviderError(
            retryCounter: 6,
            retryInterval: .seconds(5),
            successMessage: { "Reconnecting domain succeded after retry: \($0)" },
            errorBlock: { error, _ in DomainOperationErrors.reconnectDomainFailed(error) },
            operation: {
                try await fileManager.reconnect()
            }
        )
        Log.debug("Reconnected domain \(domain.displayName)", domain: .fileProvider)
    }
    
    private func disconnectDomainWithRetry(domain: NSFileProviderDomain,
                                           reason: String,
                                           options: NSFileProviderManager.DisconnectionOptions) async throws {
        guard let manager = fileProviderManagerFactory.create(for: domain) else {
            Log.error("Failed to disconnect domain due to failed manager creation", domain: .fileManager)
            return
        }
        Log.debug("Disconnecting domain \(domain.displayName)", domain: .fileProvider)
        try await Self.performWithRetryOnFileProviderError(
            retryCounter: 6,
            retryInterval: .seconds(5),
            successMessage: { "Domain disconnection succeeded after retry: \($0)" },
            errorBlock: { error, _ in DomainOperationErrors.disconnectDomainFailed(error) },
            operation: {
                try await manager.disconnect(reason: reason, options: options)
            }
        )
        Log.debug("Disconnected domain \(domain.displayName)", domain: .fileProvider)
    }
    
    private func getDomainsWithRetry() async throws -> [NSFileProviderDomain] {
        Log.debug("Getting domains", domain: .fileProvider)
        let domains = try await Self.performWithRetryOnFileProviderError(
            retryCounter: 5,
            retryInterval: .seconds(3),
            successMessage: { "Getting domains succeeded on retry \($0)" },
            errorBlock: { error, _ in
                let domainError = DomainOperationErrors.getDomainsFailed(error)
                Log.error(error: domainError, domain: .fileProvider)
                return domainError
            },
            operation: { [weak self] in
                guard let self else { return [NSFileProviderDomain]() }
                let domains: [NSFileProviderDomain]
                #if DEBUG
                if Constants.isInUITests || Constants.isInIntegrationTests {
                    // this is a temporary workaround
                    domains = (try? await self.fileProviderManagerFactory.type.domains()) ?? []
                } else {
                    domains = try await self.fileProviderManagerFactory.type.domains()
                }
                #else
                domains = try await self.fileProviderManagerFactory.type.domains()
                #endif
                return domains
            }
        )
        Log.debug("Got \(domains.count) domains", domain: .fileProvider)
        return domains
    }
    
    private func identifyDomainWithRetry() async throws {
        Log.trace()
        try await Self.performWithRetryOnFileProviderError(
            retryCounter: 5,
            retryInterval: .seconds(5),
            successMessage: { "Domain identification succeeded on retry \($0)" },
            errorBlock: { error, _ in DomainOperationErrors.identifyDomainFailed(error) },
            operation: { [weak self] in
                guard let self else { return }
                self.fileProviderDomain = try await self.domainForCurrentlyLoggedInUser()
            }
        )
        Log.trace("Identified domain")
    }
    
    private func signalEnumeratorWithRetry(fileManager: FileProviderManagerProtocol) async throws {
        try await Self.performWithRetryOnFileProviderError(
            retryCounter: 6,
            retryInterval: .seconds(5),
            successMessage: { "Signal enumerator succeeded after retry: \($0)" },
            errorBlock: { error, _ in DomainOperationErrors.signalEnumeratorFailed(error) },
            operation: {
                try await fileManager.signalEnumerator(for: .workingSet)
            }
        )
    }
    
    private func userVisibleURLForRootWithRetry(manager: FileProviderManagerProtocol) async throws -> URL {
        try await Self.performWithRetryOnFileProviderError(
            retryCounter: 5,
            retryInterval: .seconds(2),
            successMessage: { "User-visible URL for root succeeded after retry: \($0)" },
            errorBlock: { error, _ in DomainOperationErrors.getUserVisibleURLFailed(error: error) },
            operation: {
                try await manager.getUserVisibleURL(for: .rootContainer)
            }
        )
    }
    
    static func performWithRetryOnFileProviderError<T>(retryCounter: Int,
                                                       retryInterval: Duration,
                                                       successMessage: (Int) -> String,
                                                       errorBlock: (Error, Bool) -> DomainOperationErrors,
                                                       operation: @escaping () async throws -> T) async throws -> T {
        try await retryOnFileProviderError(
            retryCounter: retryCounter,
            retryInterval: retryInterval,
            successMessage: successMessage,
            errorBlock: errorBlock,
            operation: operation
        ).0
    }
    
    private static func retryOnFileProviderError<T>(retryCounter: Int,
                                                    retryInterval: Duration,
                                                    successMessage: (Int) -> String,
                                                    errorBlock: (Error, Bool) -> DomainOperationErrors,
                                                    operation: @escaping () async throws -> T) async throws -> (T, Int) {
        do {
            return (try await operation(), retryCounter)
        } catch {
            // heavily inspired by Apple's sample code (https://developer.apple.com/documentation/fileprovider/replicated_file_provider_extension/synchronizing_files_using_file_provider_extensions)
            // we know this error happens in the wild, and there's no easy way of preventing it. So let's just keep trying to get the file provider to work
            func retry() async throws -> (T, Int) {
                try await Task.sleep(for: retryInterval)
                let (result, successfulRetry) = try await retryOnFileProviderError(
                    retryCounter: retryCounter - 1, retryInterval: retryInterval,
                    successMessage: successMessage, errorBlock: errorBlock, operation: operation
                )
                if successfulRetry == retryCounter - 1 {
                    Log.info(successMessage(successfulRetry), domain: .application, sendToSentryIfPossible: true)
                }
                return (result, successfulRetry)
            }
            
            guard retryCounter > 0 else {
                throw errorBlock(error, true)
            }
            
            if #available(macOS 14.1, *) {
                let nsError = error as NSError
                switch (nsError.domain, nsError.code) {
                // TODO: remove this once we have the Xcode 15.3 or higher on release CI, because these symbols are not available at Xcode 15.2
                case (NSFileProviderErrorDomain, NSFileProviderError.Code.providerNotFound.rawValue),
                     (NSFileProviderErrorDomain, -2012), // NSFileProviderError.Code.providerDomainTemporarilyUnavailable
                     (NSFileProviderErrorDomain, -2013), // NSFileProviderError.Code.providerDomainNotFound
                     (NSFileProviderErrorDomain, NSFileProviderError.Code.domainDisabled.rawValue),
                     (NSFileProviderErrorDomain, -2014), // NSFileProviderError.Code.applicationExtensionNotFound
                     (NSURLErrorDomain, URLError.Code.cannotConnectToHost.rawValue),
                     (NSURLErrorDomain, URLError.Code.cannotFindHost.rawValue):
                    return try await retry()
                default:
                    throw errorBlock(error, false)
                }
            } else {
                switch error {
                case NSFileProviderError.providerNotFound,
                     NSFileProviderError.domainDisabled,
                     URLError.cannotConnectToHost,
                     URLError.cannotFindHost:
                    return try await retry()
                default:
                    throw errorBlock(error, false)
                }
            }
        }
    }
}

// MARK: Global Progress

extension DomainOperationsService {
    public func globalProgress(for kind: Progress.FileOperationKind) -> Progress? {
        guard let fileProviderDomain, let manager = NSFileProviderManager(for: fileProviderDomain) else { return nil }
        return manager.globalProgress(for: kind)
    }
}
#endif
