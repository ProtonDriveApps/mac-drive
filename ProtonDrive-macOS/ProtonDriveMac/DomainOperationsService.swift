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
    func getUserVisibleURL(for itemIdentifier: NSFileProviderItemIdentifier) async throws -> URL
    static func add(_ domain: NSFileProviderDomain) async throws
    static func remove(_ domain: NSFileProviderDomain, mode: NSFileProviderManager.DomainRemovalMode) async throws -> URL?
    static func domains() async throws -> [NSFileProviderDomain]
    func evictItem(identifier itemIdentifier: NSFileProviderItemIdentifier) async throws
    func disconnect(reason localizedReason: String, options: NSFileProviderManager.DisconnectionOptions) async throws
    func reconnect() async throws
}

extension NSFileProviderManager: FileProviderManagerProtocol {}

public final class DomainOperationsService: DomainOperationsServiceProtocol {
    
    @SettingsStorage("domainDisconnectedReasonCacheReset") public var cacheReset: Bool?
    
    #if HAS_QA_FEATURES
    @SettingsStorage(QASettingsConstants.disconnectDomainOnSignOut) private var disconnectDomainOnSignOut: Bool?
    #endif
    
    public var cacheCleanupStrategy: PDCore.CacheCleanupStrategy {
        hasDomainReconnectionCapability ? .doNotCleanMetadataDBNorEvents : .cleanEverything
    }
    
    public var hasDomainReconnectionCapability: Bool {
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
    
    // MARK: Public API
    
    public init(accountInfoProvider: AccountInfoProvider,
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
    
    public func identifyDomain() async throws {
        try await identifyDomainWithRetry()
    }
    
    public func setUpDomain() async throws {
        if hasDomainReconnectionCapability {
            try await connectDomain()
        } else {
            try await addNewFileProvider()
        }
    }
    
    public func connectDomain() async throws {
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
            guard domain.isDisconnected else {
                Log.debug("No need to reconnect domain \(domain.displayName) because it's already connected", domain: .fileProvider)
                return
            }
            
            do {
                try await reconnectDomainWithRetry(domain: domain)
            } catch {
                // Domain not reconnecting is a user-recoverable situation (pause/resume), so let's only log the error
                Log.error("Failed to reconnect domain because of \(error.localizedDescription)", domain: .fileProvider)
            }
        }
    }
    
    public func tearDownDomain() async throws {
        if hasDomainReconnectionCapability {
            #if HAS_QA_FEATURES
            let reason = "User signed out by disconnecting domain"
            #else
            let reason = ""
            #endif
            try await disconnectDomainsTemporarily(reason: reason)
        } else {
            try await forceDomainRemoval()
        }
    }
    
    public func forceDomainRemoval() async throws {
        try await removeFileProvider(mode: .preserveDownloadedUserData)
    }
    
    public func domainExists() async throws -> Bool {
        guard let domain = fileProviderDomain else { return false }
        let domains = try await self.getDomainsWithRetry()
        let userDomains = domains.filter { $0.identifier == domain.identifier }
        return !userDomains.isEmpty
    }
    
    public func signalEnumerator() async throws {
        guard let fileManagerForDomain else { throw NSFileProviderError(.providerNotFound) }
        try await signalEnumeratorWithRetry(fileManager: fileManagerForDomain)
    }
    
    // MARK: - Internal API
    
    func domainWasPaused() async throws {
        try await disconnectDomain(reason: pauseReason)
    }
    
    func domainWasResumed() async throws {
        try await reconnectDomain()
    }
    
    func networkConnectionLost() async throws {
        try await disconnectDomain(reason: offlineReason)
    }
    
    func disconnectDomainsTemporarily(reason: String) async throws {
        try await disconnectDomains(reason: reason)
    }
    
    func disconnectDomainsTemporarily(reason: (NSFileProviderDomain?) -> String) async throws {
        try await disconnectDomains(reason: reason(fileProviderDomain))
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
    
    func evictItem(identifier: NSFileProviderItemIdentifier) async throws {
        guard let fileManagerForDomain else { throw NSFileProviderError(.providerNotFound) }
        return try await evictItemWithRetry(manager: fileManagerForDomain, identifier: identifier)
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
        return NSFileProviderDomain(identifier: .init(accountInfo.userIdentifier), displayName: "\(accountInfo.email)-folder")
    }

    private func addressDomains() -> [NSFileProviderDomain] {
        accountInfoProvider.allAddresses
            .map { NSFileProviderDomain(identifier: .init($0), displayName: $0) }
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
            Log.error(error.localizedDescription, domain: .fileProvider)
        }

        do {
            try await addDomainWithRetry(domain)
            // if we've added a new domain, we don't need a cache reset anymore
        } catch {
            let errorMessage: String = error.localizedDescription
            Log.error(errorMessage, domain: .fileProvider)
            throw error
        }
        
        cacheReset = false
        guard domain.isDisconnected else {
            Log.debug("No need to reconnect domain \(domain.displayName) because it's already connected", domain: .fileProvider)
            return
        }
        do {
            try await reconnectDomainWithRetry(domain: domain)
        } catch {
            // Domain not reconnecting is a user-recoverable situation (pause/resume), so let's only log the error
            Log.error(error.localizedDescription, domain: .fileProvider)
        }
    }
    
    private func removeFileProvider(
        mode: NSFileProviderManager.DomainRemovalMode
    ) async throws {
        let domains = try await getDomainsWithRetry()

        var finalError: DomainOperationErrors?
        try await domains.forEach { domain in
            do {
                try await disconnectDomainWithRetry(
                    domain: domain, reason: "Proton Drive location preparing for removal", options: []
                )
            } catch {
                // even if we fail to disconnect, we still try removing, hence the error is only logged
                Log.error(error.localizedDescription, domain: .fileProvider)
            }

            do {
                try await removeDomainWithRetry(domain: domain)
            } catch let error as DomainOperationErrors {
                Log.error(error.localizedDescription, domain: .fileProvider)
                finalError = error
            }
        }

        if let finalError {
            throw finalError
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
            Log.error(error.localizedDescription, domain: .fileProvider)
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
                Log.error(error.localizedDescription, domain: .fileProvider)
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
        do {
            try await disconnectDomainWithRetry(domain: domain, reason: reason, options: [.temporary])
        } catch {
            Log.error(error.localizedDescription, domain: .fileProvider)
            throw error
        }
    }

    private func disconnectDomains(reason: String) async throws {
        // set the flag informing that the cache reset has started
        cacheReset = true
        let domains: [NSFileProviderDomain]
        domains = try await getDomainsWithRetry()

        for domain in domains {
            guard !domain.isDisconnected else { continue }
            do {
                try await disconnectDomainWithRetry(domain: domain, reason: reason, options: [.temporary])
            } catch {
                Log.debug("Failed to disconnect domain \(domain.displayName)", domain: .fileProvider)
                Log.error(error.localizedDescription, domain: .fileProvider)
                throw error
            }
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
            retryCounter: 12,
            retryInterval: .seconds(5),
            successMessage: { "Getting domains succeeded on retry \($0)" },
            errorBlock: { error, _ in
                let domainError = DomainOperationErrors.getDomainsFailed(error)
                Log.error(domainError.localizedDescription, domain: .fileProvider)
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
        Log.debug("Identifying domain", domain: .fileProvider)
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
        Log.debug("Identified domain", domain: .fileProvider)
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
    
    private func evictItemWithRetry(manager: FileProviderManagerProtocol,
                                    identifier: NSFileProviderItemIdentifier) async throws {
        try await Self.performWithRetryOnFileProviderError(
            retryCounter: 3,
            retryInterval: .seconds(1),
            successMessage: { "Evicting item succeeded after retry: \($0)" },
            errorBlock: { error, _ in DomainOperationErrors.evictItemFailed(error: error) },
            operation: {
                return try await manager.evictItem(identifier: identifier)
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

#endif
