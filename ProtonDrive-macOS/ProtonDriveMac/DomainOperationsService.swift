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

    // Storage key "domainDisconnectedReasonCacheReset" is intentionally kept for back-compat with values
    // persisted by earlier versions; do not rename it even though the property has been renamed.
    @SettingsStorage("domainDisconnectedReasonCacheReset") public var keepDomainDisconnectedForCacheRebuild: Bool?
    @SettingsStorage(UserDefaults.FileProvider.cannotSynchronizeEarlyExitOccurredKey.rawValue) private var cannotSynchronizeEarlyExitOccurred: Bool?

    #if HAS_QA_FEATURES
    @SettingsStorage(QASettingsConstants.disconnectDomainOnSignOut) private var disconnectDomainOnSignOut: Bool?
    #endif

    var hasDomainReconnectionCapability: Bool {
        assert(featureFlags() != nil, "Feature flags should be available at this point")
        let domainReconnectionEnabled = featureFlags()?.isEnabled(flag: .domainReconnectionEnabled) ?? false
        // Test-automation override (from RuntimeConfiguration) takes precedence when present; it is
        // honored only while test automation is enabled (enforced inside `forceDomainReconnection`).
        if let forced = RuntimeConfiguration.shared.forceDomainReconnection {
            return forced
        }
        #if HAS_QA_FEATURES
        let shouldDisconnect = self.disconnectDomainOnSignOut ?? domainReconnectionEnabled
        #else
        let shouldDisconnect = domainReconnectionEnabled
        #endif
        return shouldDisconnect
    }

    /// Like `hasDomainReconnectionCapability`, but safe to call before feature flags are loaded
    /// (e.g. the login screen on a fresh install): returns false when flags aren't available yet.
    var hasDomainReconnectionCapabilityIfKnown: Bool {
        guard featureFlags() != nil else { return false }
        return hasDomainReconnectionCapability
    }

    private let offlineReason = "🛜 Your internet connection seems to be offline."
    private let pauseReason = "These files will not be synced while Proton Drive is paused."
    private let fullResyncReason = "Full resync in progress..."

    private let accountInfoProvider: AccountInfoProvider
    private let featureFlags: () -> PDCore.DriveFeatureFlagsProvider?
    private let fileProviderManagerFactory: any FileProviderManagerFactory
    private let assertionProvider: any AssertionProvider

    // Domain state is shared with background callers. Keep each read/check/write synchronous;
    // no domain operation needs to hop to the main actor to validate its session.
    private struct DomainState {
        var sessionGeneration: UUID?
        var currentDomain: NSFileProviderDomain?
        var removals: [UUID: Task<Void, Error>] = [:]
        // Detects removals that start during discovery, even if they finish before discovery returns.
        var removalGeneration = UUID()
    }
    private let domainStateLock = NSLock()
    private var domainState = DomainState()

    private var sessionGeneration: UUID? { withDomainState { $0.sessionGeneration } }

    #if HAS_QA_FEATURES
    var currentDomain: NSFileProviderDomain? { withDomainState { $0.currentDomain } }
    #else
    private var currentDomain: NSFileProviderDomain? { withDomainState { $0.currentDomain } }
    #endif

    private var fileManagerForDomain: FileProviderManagerProtocol? {
        currentDomain.flatMap(fileProviderManagerFactory.create(for:))
    }

    init(accountInfoProvider: AccountInfoProvider,
         featureFlags: @escaping () -> PDCore.DriveFeatureFlagsProvider?,
         fileProviderManagerFactory: any FileProviderManagerFactory,
         assertionProvider: AssertionProvider = SystemAssertionProvider.instance) {
        self.accountInfoProvider = accountInfoProvider
        self.featureFlags = featureFlags
        self.fileProviderManagerFactory = fileProviderManagerFactory
        self.assertionProvider = assertionProvider
        _keepDomainDisconnectedForCacheRebuild.configure(with: Constants.appGroup)
        _cannotSynchronizeEarlyExitOccurred.configure(with: Constants.appGroup)

        #if HAS_QA_FEATURES
        _disconnectDomainOnSignOut.configure(with: Constants.appGroup)
        #endif
    }

    // MARK: Session lifecycle

    /// AppCoordinator supplies a new token at login, logout, and fresh-domain recovery.
    /// A delayed operation from an earlier session must not publish a domain for the new one.
    /// DomainOperationsService coordinates physical removals with discovery because changing
    /// the session token cannot stop a removal already running in FileProvider.
    func useSessionGeneration(_ generation: UUID) {
        withDomainState { $0.sessionGeneration = generation }
    }

    private func requireCurrentSession(_ generation: UUID?) throws {
        guard generation == sessionGeneration else { throw CancellationError() }
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
            try await disconnectAllDomains(reason: reason)
        } else {
            try await removeAllDomains()
        }
    }

    public func signalEnumerator(reason: FileOperationEvent.SignalEnumeratorReason) async throws {
        Log.event(.signalEnumerator(.started(.init(containerType: .workingSet, reason: reason))))

        guard let fileManagerForDomain else { throw NSFileProviderError(.providerNotFound) }
        do {
            try await signalEnumeratorWithRetry(fileManager: fileManagerForDomain)
            Log.event(.signalEnumerator(.succeeded(.init(containerType: .workingSet, reason: reason))))
        } catch {
            Log.event(.signalEnumerator(.failed(.init(
                id: NSFileProviderItemIdentifier.workingSet.logIdentifier,
                error: error
            ))))
            throw error
        }
    }

    public func removeAllDomains() async throws {
        let generation = sessionGeneration
        let domains = try await getDomainsWithRetry()

        var finalError: DomainOperationErrors?
        try await domains.forEach { domain in
            try Task.checkCancellation()
            try requireCurrentSession(generation)
            do {
                try await disconnectDomainWithRetry(
                    domain: domain, reason: "Proton Drive location preparing for removal", options: []
                )
            } catch {
                // even if we fail to disconnect, we still try removing, hence the error is only logged
                Log.error(error: error, domain: .fileProvider)
            }

            do {
                try await removeDomainWithRetry(domain: domain, generation: generation)
            } catch is CancellationError {
                // A newer session owns the domains now; abandon the rest of the loop to it.
                Log.info(
                    "Domain removal superseded — abandoning remaining removals",
                    domain: .fileProvider
                )
                throw CancellationError()
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
        try await disconnectCurrentDomain(reason: "One-time migration for Sequoia")
    }

    // MARK: - Resolving errors

    public func tryResolvingErrors() async {
        await tryResolving(error: NSFileProviderError(.notAuthenticated))
        await tryResolving(error: NSFileProviderError(.insufficientQuota))
        await tryResolving(error: NSFileProviderError(.serverUnreachable))
        await tryResolvingCannotSynchronizeError()
    }

    /// Signals that the `.cannotSynchronize` condition is resolved — but only if the file provider
    /// actually deferred an operation with it (tracked across processes via the early-exit flag),
    /// so the system retries those operations once the domain is back.
    public func tryResolvingCannotSynchronizeErrorIfDeferred() async {
        guard cannotSynchronizeEarlyExitOccurred == true else { return }
        await tryResolvingCannotSynchronizeError()
        cannotSynchronizeEarlyExitOccurred = false
    }

    private func tryResolvingCannotSynchronizeError() async {
        await tryResolving(error: NSFileProviderError(.cannotSynchronize))
    }

    private func tryResolving(error: any Error) async {
        do {
            try await signalErrorResolved(error)
        } catch {
            Log.error("signalErrorResolved failed", error: error, domain: .fileProvider)
        }
    }

    func cleanUpErrors() {
        Task {
            await tryResolvingErrors()
        }
    }

    private func signalErrorResolved(_ error: any Error) async throws {
        guard let fileManagerForDomain else { throw NSFileProviderError(.providerNotFound) }

        try await fileManagerForDomain.signalErrorResolved(error)
    }

    // MARK: - Internal API

    func identifyCurrentDomain(generation: UUID? = nil) async throws {
        try await identifyCurrentDomainWithRetry(generation: generation)
    }

    func setUpDomain(generation: UUID? = nil) async throws {
        if hasDomainReconnectionCapability {
            try await connectCurrentDomain(generation: generation)
        } else {
            try await addCurrentDomainDisconnectingAllOthers(generation: generation)
        }
    }

    /// The domain identified or set up by this session. Callers that skip `setUpDomain()` still need it.
    func requireCurrentDomain() throws -> NSFileProviderDomain {
        guard let currentDomain else { throw NSFileProviderError(.providerNotFound) }
        return currentDomain
    }

    func connectCurrentDomain(generation: UUID? = nil) async throws {
        let generation = generation ?? sessionGeneration
        try Task.checkCancellation()
        try requireCurrentSession(generation)
        guard let domain = currentDomain else {
            // identify domain
            try await identifyCurrentDomainWithRetry(generation: generation)
            // retry
            try await connectCurrentDomain(generation: generation)
            return
        }

        let userDomains = try await removeDomains(otherThan: domain, generation: generation)
        try Task.checkCancellation()
        try requireCurrentSession(generation)

        if !userDomains.isEmpty {
            // Don't reconnect a stale domain while the cache rebuild is pending; the login-reconnection
            // resync reconnects it once the rebuild succeeds (mirrors reconnectCurrentDomain).
            guard keepDomainDisconnectedForCacheRebuild != true else { return }
            try await reconnectDomainWithRetry(domain: domain, generation: generation)
        } else {
            try await addDomainWithRetry(domain, generation: generation)

            try Task.checkCancellation()
            try requireCurrentSession(generation)
            keepDomainDisconnectedForCacheRebuild = false
            // IMPORTANT: there was `guard!domain.isDisconnected else { return }` check before
            // but we've found out we shouldn't rely on this property.
            // It's not updated after the initial domain fetching.
            // We could make a `getDomain` call before checking it here, but I believe it's unnecessary.

            do {
                try await reconnectDomainWithRetry(domain: domain, generation: generation)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Domain not reconnecting is a user-recoverable situation (pause/resume), so let's only log the error
                Log.error("Failed to reconnect domain", error: error, domain: .fileProvider)
            }
        }
    }

    func currentDomainExists() async throws -> Bool {
        guard let domain = currentDomain else { return false }
        let domains = try await self.getDomainsWithRetry()
        let userDomains = domains.filter { $0.identifier == domain.identifier }
        return !userDomains.isEmpty
    }

    func syncWasPaused() async throws {
        try await disconnectCurrentDomain(reason: pauseReason)
    }

    func performingFullResync() async throws {
        try await disconnectCurrentDomain(reason: fullResyncReason)
    }

    func syncWasResumed() async throws {
        try await reconnectCurrentDomain()
    }

    func networkConnectionLost() async throws {
        try await disconnectCurrentDomain(reason: offlineReason)
    }

    func disconnectAllDomainsDuringMainKeyCleanup() async throws {
        try await disconnectAllDomains(
            reason: "Attempting to reconnect. This may take a few minutes. Please do not quit the application"
        )
    }

    #if HAS_QA_FEATURES
    func disconnectDomainsForQA(reason: (NSFileProviderDomain?) -> String) async throws {
        try await disconnectAllDomains(reason: reason(currentDomain))
    }
    #endif

    func disconnectCurrentDomainBeforeAppClosing() async throws {
        try await disconnectCurrentDomain(reason: "Proton Drive needs to be running in order to sync these files.")
    }

    func dumpingStarted() async throws {
        try await disconnectCurrentDomain(reason: "Dumping FS...")
    }

    func cleanAfterDumping() {
        if keepDomainDisconnectedForCacheRebuild != true {
            Task {
                try await reconnectCurrentDomain()
            }
        }
    }

    func getUserVisibleURLForRoot() async throws -> URL {
        guard let fileManagerForDomain else { throw NSFileProviderError(.providerNotFound) }
        return try await userVisibleURLForRootWithRetry(manager: fileManagerForDomain)
    }

    // MARK: - Private API

    private func withDomainState<T>(_ operation: (inout DomainState) throws -> T) rethrows -> T {
        domainStateLock.lock()
        defer { domainStateLock.unlock() }
        return try operation(&domainState)
    }

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

    private func addCurrentDomainDisconnectingAllOthers(generation: UUID? = nil) async throws {
        let generation = generation ?? sessionGeneration
        try Task.checkCancellation()
        try requireCurrentSession(generation)
        guard let domain = currentDomain else {
            // identify domain
            try await identifyCurrentDomainWithRetry(generation: generation)
            // retry
            try await addCurrentDomainDisconnectingAllOthers(generation: generation)
            return
        }

        // for the cleanup, we try removing the old domains before adding a new one
        // however, if this cleanup fails, we do continue
        do {
            _ = try await removeDomains(otherThan: domain, generation: generation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.error(error: error, domain: .fileProvider)
        }

        do {
            try await addDomainWithRetry(domain, generation: generation)
            // if we've added a new domain, we don't need a cache reset anymore
        } catch {
            Log.error(error: error, domain: .fileProvider)
            throw error
        }

        try Task.checkCancellation()
        try requireCurrentSession(generation)
        keepDomainDisconnectedForCacheRebuild = false
        // IMPORTANT: there was `guard !domain.isDisconnected else { return }` check before
        // but we've found out we shouldn't rely on this property.
        // It's not updated after the initial domain fetching.
        // We could make a `getDomain` call before checking it here, but I believe it's unnecessary.
        do {
            try await reconnectDomainWithRetry(domain: domain, generation: generation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Domain not reconnecting is a user-recoverable situation (pause/resume), so let's only log the error
            Log.error(error: error, domain: .fileProvider)
        }
    }

    private func reconnectCurrentDomain() async throws {
        // do not reconnect if we're recreating the cache
        guard keepDomainDisconnectedForCacheRebuild != true else { return }

        guard let currentDomain else {
            // identify domain
            try await identifyCurrentDomainWithRetry()
            // retry
            try await reconnectCurrentDomain()
            return
        }

        do {
            try await reconnectDomainWithRetry(domain: currentDomain)
            await tryResolvingCannotSynchronizeErrorIfDeferred()
        } catch {
            Log.error(error: error, domain: .fileProvider)
            throw error
        }
    }

    private func removeDomains(otherThan domain: NSFileProviderDomain, generation: UUID?) async throws -> [NSFileProviderDomain] {
        try Task.checkCancellation()
        try requireCurrentSession(generation)
        let domains = try await getDomainsWithRetry()

        let userDomains = domains.filter { $0.identifier == domain.identifier }
        let oldDomains = domains.filter { $0.identifier != domain.identifier }

        var finalError: DomainOperationErrors?
        for oldDomain in oldDomains {
            do {
                try await removeDomainWithRetry(domain: oldDomain, generation: generation)
            } catch is CancellationError {
                // A newer session owns the domains now; abandon the rest of the loop to it.
                Log.info(
                    "Domain removal superseded — abandoning remaining removals",
                    domain: .fileProvider
                )
                throw CancellationError()
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

    private func disconnectCurrentDomain(reason: String) async throws {
        guard let domain = currentDomain else {
            Log.info("Current domain cannot be disconnected because it's not available", domain: .fileManager)
            return
        }

        try await disconnect(domain: domain, reason: reason)
    }

    private func disconnectAllDomains(reason: String) async throws {
        // set the flag informing that the cache reset has started
        keepDomainDisconnectedForCacheRebuild = true
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

    private func addDomainWithRetry(_ domain: NSFileProviderDomain, generation: UUID?) async throws {
        Log.debug("Adding domain \(domain.displayName)", domain: .fileProvider)
        try await Self.performWithRetryOnFileProviderError(
            retryCounter: 6,
            retryInterval: .seconds(5),
            successMessage: { "Signal enumerator succeeded after retry: \($0)" },
            errorBlock: { error, _ in DomainOperationErrors.addDomainFailed(error) },
            operation: { [weak self] in
                guard let self else { return }
                do {
                    try Task.checkCancellation()
                    try self.requireCurrentSession(generation)
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

    private func removeDomainWithRetry(domain: NSFileProviderDomain, generation: UUID?) async throws {
        Log.debug("Removing domain \(domain.displayName)", domain: .fileProvider)
        try await Self.performWithRetryOnFileProviderError(
            retryCounter: 3,
            retryInterval: .seconds(5),
            successMessage: { "Domain removal succeded after retry \($0)" },
            errorBlock: { error, _ in DomainOperationErrors.removeDomainFailed(error) },
            operation: { [weak self] in
                guard let self else { return }
                // A sign-out can be suspended in removal while the same user signs in again.
                // Register the removal before starting it so new discovery waits for it to finish.
                // A session token cannot cancel a removal already executing in FileProvider.
                try Task.checkCancellation()
                try self.requireCurrentSession(generation)
                let removal = try self.withDomainState { state in
                    guard generation == state.sessionGeneration else { throw CancellationError() }
                    let id = UUID()
                    let task = Task {
                        defer { self.withDomainState { $0.removals[id] = nil } }
                        _ = try await self.fileProviderManagerFactory.type.remove(domain, mode: .preserveDownloadedUserData)
                        self.withDomainState { state in
                            if generation == state.sessionGeneration,
                               state.currentDomain?.identifier == domain.identifier {
                                state.currentDomain = nil
                            }
                        }
                    }
                    state.removalGeneration = UUID()
                    state.removals[id] = task
                    return task
                }
                try await removal.value
                try Task.checkCancellation()
                try self.requireCurrentSession(generation)
            }
        )
        Log.debug("Removed domain \(domain.displayName)", domain: .fileProvider)
    }

    private func reconnectDomainWithRetry(domain: NSFileProviderDomain, generation: UUID? = nil) async throws {
        let generation = generation ?? sessionGeneration
        try Task.checkCancellation()
        try requireCurrentSession(generation)
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
                try Task.checkCancellation()
                try self.requireCurrentSession(generation)
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

    private func identifyCurrentDomainWithRetry(generation: UUID? = nil) async throws {
        let generation = generation ?? sessionGeneration
        Log.trace()
        try await Self.performWithRetryOnFileProviderError(
            retryCounter: 5,
            retryInterval: .seconds(5),
            successMessage: { "Domain identification succeeded on retry \($0)" },
            errorBlock: { error, _ in DomainOperationErrors.identifyDomainFailed(error) },
            operation: { [weak self] in
                guard let self else { return }
                while true {
                    try Task.checkCancellation()
                    try self.requireCurrentSession(generation)
                    let pending = self.withDomainState {
                        (
                            removals: Array($0.removals.values),
                            removalGeneration: $0.removalGeneration
                        )
                    }
                    for removal in pending.removals {
                        // Even a failed removal must finish before we inspect the system again.
                        _ = await removal.result
                    }
                    try Task.checkCancellation()
                    try self.requireCurrentSession(generation)
                    let domain = try await self.domainForCurrentlyLoggedInUser()
                    try Task.checkCancellation()
                    let published = try self.withDomainState { state in
                        guard generation == state.sessionGeneration else { throw CancellationError() }
                        // Another removal may have started while domain discovery was suspended.
                        guard state.removals.isEmpty,
                              state.removalGeneration == pending.removalGeneration else { return false }
                        state.currentDomain = domain
                        return true
                    }
                    if published { return }
                }
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
            if error is CancellationError { throw error }
            // heavily inspired by Apple's sample code (https://developer.apple.com/documentation/fileprovider/replicated_file_provider_extension/synchronizing_files_using_file_provider_extensions)
            // we know this error happens in the wild, and there's no easy way of preventing it. So let's just keep trying to get the file provider to work
            func retry() async throws -> (T, Int) {
                try await Task.sleep(for: retryInterval)
                let (result, successfulRetry) = try await retryOnFileProviderError(
                    retryCounter: retryCounter - 1,
                    retryInterval: retryInterval,
                    successMessage: successMessage,
                    errorBlock: errorBlock,
                    operation: operation
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
