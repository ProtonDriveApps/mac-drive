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

import AppKit
import Combine
import FileProvider
import PDCore
import PDClient
import PDFileProvider
import ProtonCoreLog
import ProtonCoreCryptoGoInterface
import ProtonCoreUtilities
import PDUploadVerifier
import ProtonCoreCryptoPatchedGoImplementation
import PDFileProviderOperations
import PMEventsManager
import PDSDKCore

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    @SettingsStorage(UserDefaults.FileProvider.workingSetEnumerationInProgressKey.rawValue) var workingSetEnumerationInProgress: Bool?
    @SettingsStorage(UserDefaults.FileProvider.shouldReenumerateItemsKey.rawValue) var shouldReenumerateItems: Bool?
    @SettingsStorage("domainDisconnectedReasonCacheReset") public var cacheReset: Bool?
    @SettingsStorage(UserDefaults.FileProvider.pathsMarkedAsKeepDownloadedKey.rawValue) var pathsMarkedAsKeepDownloaded: String?
    @SettingsStorage(UserDefaults.FileProvider.pathsMarkedAsOnlineOnlyKey.rawValue) var pathsMarkedAsOnlineOnly: String?
    @SettingsStorage(UserDefaults.FileProvider.openItemsInBrowserKey.rawValue) var openItemsInBrowser: String?
    @SettingsStorage(UserDefaults.FileProvider.extensionPathKey.rawValue) var fileProviderExtensionPath: String?

    private var isForceRefreshing: Bool = false
    
    private let domain: NSFileProviderDomain // use domain to support multiple accounts
    private let manager: NSFileProviderManager
    
    private var observer: NSKeyValueObservation?
    private var networkCancellable: AnyCancellable?

    var tower: Tower { postLoginServices.tower }

    private lazy var syncReporter = SyncReporter(tower: tower, manager: manager)
    
    private var fileProviderOperations: FileProviderOperationsProtocol!
    private var progresses = FileOperationProgresses()
    
    private lazy var itemProvider = ItemProvider()
    private lazy var keymaker = DriveKeymaker(autolocker: nil, keychain: DriveKeychain.shared,
                                              logging: { Log.info($0, domain: .storage) })

    private var enumerationObserver: EnumerationObserver!

    private lazy var initialServices = InitialServices(
        userDefault: Constants.appGroup.userDefaults,
        clientConfig: Constants.userApiConfig,
        mainKeyProvider: keymaker,
        autoLocker: nil,
        sessionRelatedCommunicatorFactory: { sessionStore, authenticator, onSessionReceived in
            SessionRelatedCommunicatorForExtension(
                userDefaultsConfiguration: .forFileProviderExtension(userDefaults: Constants.appGroup.userDefaults),
                sessionStorage: sessionStore,
                onChildSessionObtained: onSessionReceived
            )
        },
        isDetailedLoggingEnabled: { RuntimeConfiguration.shared.includeTracesInLogs }
    )

    private lazy var postLoginServices = PostLoginServices(
        initialServices: initialServices,
        appGroup: Constants.appGroup,
        eventObservers: [],
        eventProcessingMode: .processRecords,
        eventLoopInterval: RuntimeConfiguration.shared.eventLoopInterval,
        uploadVerifierFactory: ConcreteUploadVerifierFactory(),
        activityObserver: { [weak self] activity in
            self?.currentActivityChanged(activity)
        }
    )

    private lazy var keepDownloadedManager = KeepDownloadedEnumerationManager(
        fileSystemSlot: tower.fileSystemSlot,
        fileProviderManager: manager
    )

    private let observationCenter: PDCore.UserDefaultsObservationCenter
    private var systemMetricsMonitor: SystemMetricsMonitor?

    required init(domain: NSFileProviderDomain) {
        inject(cryptoImplementation: ProtonCoreCryptoPatchedGoImplementation.CryptoGoMethodsImplementation.instance)
        // Inject build type to enable build differentiation. (Build macros don't work in SPM)
        PDCore.Constants.buildType = Constants.buildType

        // the logger setup happens before the super.init, hence the captured `client` and `featureFlags` variables
        var featureFlags: PDCore.FeatureFlagsRepository?
        Constants.loadConfiguration()
        configureCoreLoggerUsingEnvironmentFromConstants()
        FileProviderExtension.setupLogger { featureFlags }

        if RuntimeConfiguration.shared.includeTracesInLogs {
            let monitor = SystemMetricsMonitor(
                interval: RuntimeConfiguration.shared.systemMetricsMonitoringInterval,
                volumeURL: FileManager.default.homeDirectoryForCurrentUser
            )
            monitor.start()
            systemMetricsMonitor = monitor
        }
        
        Log.event(.extensionInit(.started(.init(
            domainIdentifier: domain.identifier.rawValue,
            backingStoreIdentifier: domain.backingStoreIdentity?.base64EncodedString() ?? "nil"
        ))))
        
        let lastLineBeforeHanging: Atomic<Int> = .init(#line)
        func updateLastLineBeforeHanging(line: Int = #line) { lastLineBeforeHanging.mutate { $0 = line } }
        let hangLogCancellation = performUnlessCancelled(after: .seconds(60)) {
            let message = "FileProviderExtension.init hangs after line \(lastLineBeforeHanging.value)"
            Log.warning(message, domain: .fileProvider, sendToSentryIfPossible: true)
        }
        defer {
            let hasCancelled = hangLogCancellation()
            if !hasCancelled {
                Log.info("False positive cancellation info sent to Sentry",
                         domain: .fileProvider,
                         sendToSentryIfPossible: true)
            } else {
                Log.info("No hang in FileProviderExtension.init identified",
                         domain: .fileProvider,
                         sendToSentryIfPossible: false)
            }
        }
        
        self.domain = domain
        guard let manager = NSFileProviderManager(for: domain) else {
            let message = "File provider manager is required by the file provider extension to operate"
            Log.event(.extensionInit(.failed(.init(
                id: domain.identifier.rawValue,
                errorMessage: message
            ))))
            fatalError(message)
        }
        self.manager = manager
        updateLastLineBeforeHanging()
        
        _shouldReenumerateItems.configure(with: Constants.appGroup)
        _openItemsInBrowser.configure(with: Constants.appGroup)
        _cacheReset.configure(with: Constants.appGroup)
        _fileProviderExtensionPath.configure(with: Constants.appGroup)
        updateLastLineBeforeHanging()
        
        self.observationCenter = UserDefaultsObservationCenter(userDefaults: Constants.appGroup.userDefaults)
        updateLastLineBeforeHanging()
        
        super.init()
        updateLastLineBeforeHanging()

        let syncStorage = tower.syncStorage ?? SyncStorageManager(suite: Constants.appGroup)
        updateLastLineBeforeHanging()
        
        self.enumerationObserver = EnumerationObserver(syncStorage: syncStorage)
        updateLastLineBeforeHanging()
        
        self.setUpFileProviderOperations()
        updateLastLineBeforeHanging()
        
        // expose featureFlags to logger
        featureFlags = tower.featureFlags
        updateLastLineBeforeHanging()
        
        let context = tower.storage.synchronousContextPool.acquire()
        defer { tower.storage.synchronousContextPool.relinquish(context) }
        guard tower.rootFolderAvailable(moc: context) else {
            let message = "No root folder means the database was not bootstrapped yet by the main app. Disconnect the domain until the app reconnects it."
            Log.event(.extensionInit(.failed(.init(
                id: domain.identifier.rawValue,
                errorMessage: message
            ))))
            updateLastLineBeforeHanging()
            disconnectDomainDueToSignOut()
            return
        }
        updateLastLineBeforeHanging()
        
        // this line covers a rare scenario in which the child session credentials
        // were fetched and saved to keychain by the main app, but file provider extension
        // somehow did not get informed about them through the user defaults.
        // the one confirmed case of this scenario happening was when user denied access
        // to group container on the Sequoia, so the user defaults were not available
        tower.sessionVault.consumeChildSessionCredentials()
        updateLastLineBeforeHanging()
        
        self.clearDrafts()
        updateLastLineBeforeHanging()
        
        self.tower.start(options: [])
        updateLastLineBeforeHanging()

        #if DEBUG
        NetworkSimulation.startObserving()
        #endif
        tower.connectionStateResource.startMonitoring()
        self.startObservingNetworkState()
        updateLastLineBeforeHanging()

        self.startObservingRunningAppChanges()
        updateLastLineBeforeHanging()

        let completed: Bool = SyncAwait.run(timeout: .seconds(3)) {
            await self.syncReporter.cleanUpOnLaunch()
        }
        if !completed {
            Log.warning("cleanUpOnLaunch timed out after 3s, proceeding with launch", domain: .fileProvider, sendToSentryIfPossible: true)
        }
        updateLastLineBeforeHanging()

        self.setUpKeepDownloadedObservers()
        updateLastLineBeforeHanging()

        self.reenumerateIfNecessary()
        updateLastLineBeforeHanging()

        postExtensionLaunchNotification()
        updateLastLineBeforeHanging()
        
        Log.event(.extensionInit(.succeeded(.init(
            domainIdentifier: domain.identifier.rawValue
        ))))
    }

    private func postExtensionLaunchNotification() {
        guard let extensionExecutablePath = Bundle.main.executablePath else {
            Log.error("Unable to get executable path for FileProviderExtension", domain: .fileProvider)
            return
        }

        fileProviderExtensionPath = extensionExecutablePath

        Log.trace("FileProviderExtension launched from \(extensionExecutablePath)", domain: .fileProvider)
    }

    private func setUpKeepDownloadedObservers() {
        self.observationCenter.addObserver(self, of: \.pathsMarkedAsKeepDownloaded) { [weak self] value in
            guard value??.isEmpty == false, let itemIdentifiers = value??.components(separatedBy: ":").map({ NSFileProviderItemIdentifier($0) }) else {
                return
            }

            // Reset after using, so that next time the same folder is selected, it registers as an update.
            self?.pathsMarkedAsKeepDownloaded = ""

            Task {
                await self?.tower.storage.backgroundContextPool.withContext { moc in
                    Log.trace("Found \(itemIdentifiers.count) itemIdentifiers to keep downloaded")
                    for itemIdentifier in itemIdentifiers {
                        Log.trace("Marking as \"Available offline\": \(itemIdentifier)")
                        _ = self?.setKeepDownloaded(true, itemsWithIdentifiers: itemIdentifiers, moc: moc)
                    }
                }
            }
        }

        self.observationCenter.addObserver(self, of: \.pathsMarkedAsOnlineOnly) { [weak self] value in
            guard value??.isEmpty == false, let itemIdentifiers = value??.components(separatedBy: ":").map({ NSFileProviderItemIdentifier($0) }) else {
                return
            }

            // Reset after using, so that next time the same folder is selected, it registers as an update.
            self?.pathsMarkedAsOnlineOnly = ""

            Task {
                await self?.tower.storage.backgroundContextPool.withContext { moc in
                    Log.trace("Found \(itemIdentifiers.count) itemIdentifiers to mark as online only")
                    for itemIdentifier in itemIdentifiers {
                        Log.trace("Marking as \"Online only\": \(itemIdentifier)")
                        _ = self?.setKeepDownloaded(false, itemsWithIdentifiers: itemIdentifiers, moc: moc)
                    }
                }
            }
        }
    }

    private func setUpFileProviderOperations() {
        let legacyFileProviderOperations = LegacyFileProviderOperations(
            tower: tower,
            syncReporter: syncReporter,
            itemProvider: itemProvider,
            manager: manager,
            progresses: progresses,
            enableRegressionTestHelpers: RuntimeConfiguration.shared.enableTestAutomation,
            downloadCollector: DBPerformanceMeasurementCollector(operationType: .download),
            uploadCollector: DBPerformanceMeasurementCollector(operationType: .upload)
        )

        do {
            self.fileProviderOperations = try SyncAwait.run {
                try await SDKFileProviderOperations(
                    tower: self.tower,
                    syncReporter: self.syncReporter,
                    fileProviderManager: self.manager,
                    progresses: self.progresses,
                    enableRegressionTestHelpers: RuntimeConfiguration.shared.enableTestAutomation,
                    downloadPerformanceCollector: DBPerformanceMeasurementCollector(operationType: .download),
                    uploadPerformanceCollector: DBPerformanceMeasurementCollector(operationType: .upload)
                )
            }
        } catch {
            fatalError("Unable to initialize SDK: \(error)")
        }
    }

    private func clearDrafts() {
        do {
            let client = tower.client
            let draftWasCleared = try tower.storage.clearDrafts(
                moc: tower.storage.backgroundContext,
                deleteDraft: tower.fileUploader.performDeletionOfUploadingFileOutsideMOC,
                deleteRevisionOnBE: { revision in
                    guard revision.state == .draft else { return }
                    let identifier = revision.identifier
                    client.deleteRevision(identifier.revisionID, identifier.fileID, shareID: identifier.shareID) { _ in
                        // The result is ignored because deleting revision draft is not strictly required.
                        // * the revision will be cleared after 4 hours by backend's collector
                        // * (once it's implemented) during the revision upload, if the draft revision already exists and its uploadClientUID
                        //   matches the new revision, we will delete the revision draft as we do delete the file draft
                    }
                },
                includingAlreadyUploadedFiles: true)
            if draftWasCleared {
                Log.event(.signalEnumerator(.started(.init(containerType: .workingSet, reason: .draftsCleared))))
                manager.signalEnumerator(for: .workingSet) { error in
                    if let error {
                        Log.event(.signalEnumerator(.failed(.init(
                            id: NSFileProviderItemIdentifier.workingSet.logIdentifier, error: error
                        ))))
                    } else {
                        Log.event(.signalEnumerator(.succeeded(.init(
                            containerType: .workingSet, reason: .draftsCleared
                        ))))
                    }
                    guard let error else { return }
                    Log.error("Failed to signal enumerator after clearing drafts",
                              error: error, domain: .enumerating)
                }
            }
        } catch {
            Log.error("Failed to clear drafts", error: error, domain: .storage)
        }
    }

    private func reenumerateIfNecessary() {
        if shouldReenumerateItems == true || workingSetEnumerationInProgress == true {
            Log.event(.signalEnumerator(.started(.init(containerType: .workingSet, reason: .reenumerationRequired))))
            manager.signalEnumerator(for: .workingSet) { [weak self] error in
                if let error {
                    Log.event(.signalEnumerator(.failed(.init(
                        id: NSFileProviderItemIdentifier.workingSet.logIdentifier, error: error
                    ))))
                } else {
                    Log.event(.signalEnumerator(.succeeded(.init(
                        containerType: .workingSet, reason: .reenumerationRequired
                    ))))
                }
                guard let error else { return }
                let sei = self?.shouldReenumerateItems.map(\.description) ?? "nil"
                let wseip = self?.workingSetEnumerationInProgress.map(\.description) ?? "nil"
                Log.error("Failed to signal enumerator due to shouldReenumerateItems \(sei) or workingSetEnumerationInProgress \(wseip): \(error.localizedDescription)",
                          domain: .enumerating)
            }
        }
    }

    deinit {
        observationCenter.removeObserver(self)
    }
    
    private static func setupLogger(featureFlagsGetter: @escaping () -> PDCore.FeatureFlagsRepository?) {
        let localSettings = LocalSettings.shared
        SentryClient.shared.start(localSettings: localSettings)

        let shouldCompressLogs = featureFlagsGetter()?.isEnabled(flag: .logsCompressionDisabled) ?? false
        Log.configure(system: .macOSFileProvider, compressLogs: shouldCompressLogs)

        PDClient.logInfo = { Log.info($0, domain: .fileProvider) }
        PDClient.logError = { Log.error($0, domain: .fileProvider) }
        PMEventsManager.log = { Log.trace($0, file: $1, function: $2, line: $3) }

#if HAS_QA_FEATURES
        DarwinNotificationCenter.shared.addObserver(self, for: .SendErrorEventToTestSentry) { _ in
            let originalLogger = Log.logger
            // Temporarily replace logger to test Sentry events sending
            Log.logger = ProductionLogger()
            let error = NSError(domain: "FILEPROVIDER SENTRY TESTING", code: 0, localizedDescription: "Test from file provider")
            Log.error(error: error, domain: .fileProvider)
            // Restore original logger after the test
            Log.logger = originalLogger
        }
        DarwinNotificationCenter.shared.addObserver(self, for: .DoCrashToTestSentry) { _ in
            fatalError("FileProvider: Forced crash to test Sentry crash reporting")
        }
#endif
        
        NotificationCenter.default.addObserver(forName: .NSApplicationProtectedDataDidBecomeAvailable, object: nil, queue: nil) { _ in
            Log.info("Notification.Name.NSApplicationProtectedDataDidBecomeAvailable", domain: .fileProvider)
        }
        NotificationCenter.default.addObserver(forName: .NSApplicationProtectedDataWillBecomeUnavailable, object: nil, queue: nil) { _ in
            Log.info("Notification.Name.NSApplicationProtectedDataWillBecomeUnavailable", domain: .fileProvider)
        }
    }

    func invalidate() {
        Log.event(.extensionInvalidate(.started(.init(
            domainIdentifier: domain.identifier.rawValue
        ))))
        networkCancellable?.cancel()
        stopObservingRunningAppChanges()
        tower.stop()
        tower.sessionCommunicator.stopObservingSessionChanges()
        progresses.cancelAll(reason: .fileProviderDeinited)

        let completed: Bool = SyncAwait.run(timeout: .seconds(3)) {
            await self.syncReporter.cleanUpOnInvalidate()
        }
        if !completed {
            Log.warning("cleanUpOnInvalidate timed out after 3s, proceeding with invalidation", domain: .fileProvider, sendToSentryIfPossible: true)
        }
        
        Log.event(.extensionInvalidate(.succeeded(.init(
            domainIdentifier: domain.identifier.rawValue
        ))))
    }

    private func currentActivityChanged(_ activity: NSUserActivity) {
        switch activity {
        default:
            break
        }
    }
    
    func importDidFinish() async {
        Log.info("Import did finish", domain: .application)
    }
    
    private func startObservingRunningAppChanges() {
        Log.info("Starts monitoring the menu bar app", domain: .application)
        self.runningAppsChangeHandler(NSWorkspace.shared)
        self.observer = NSWorkspace.shared
            .observe(\.runningApplications, options: [.new, .old],
                      changeHandler: { [weak self] workspace, _ in self?.runningAppsChangeHandler(workspace) })
    }

    private func runningAppsChangeHandler(_ workspace: NSWorkspace) {
        // There is a mysterious crash on Sentry with "NSRunningApplication > Attempted to dereference null pointer".
        // Since it's a crash in underlying Obj-C code, stacktrace points it's related to an array copy,
        // I've decided it's best to not pass the workspace and access runningApplications from the Task.
        let runningApplicationBundleIdentifiers = workspace.runningApplications.compactMap(\.bundleIdentifier)
        // we dispatch to Task because there's no need to keep the calling thread waiting
        // on the `getDomainsWithCompletionHandler` call
        Task(priority: .userInitiated) { [weak self] in
            // the error is ignored by design — if there's an error, we just rely on the `self.domain` state
            let domains = (try? await NSFileProviderManager.domains()) ?? []
                
            guard let self else { return }
            
            let isAppRunning = runningApplicationBundleIdentifiers.contains { Self.isMenuBarAppIdentified($0) }
            
            let context = self.tower.storage.synchronousContextPool.acquire()
            let isSignedIn = self.tower.rootFolderAvailable(moc: context)
            self.tower.storage.synchronousContextPool.relinquish(context)

            let currentDomain = domains.first(where: { $0.identifier == self.domain.identifier }) ?? self.domain
            let isDomainConnected = !currentDomain.isDisconnected
            
            if !isAppRunning && isSignedIn && isDomainConnected {
                self.disconnectDomainDueToMenuBarAppNotRunning()
            } else if isAppRunning && isSignedIn && !isDomainConnected {
                self.connectDomainDueToMenuBarAppRunning()
            } else if !isSignedIn && isDomainConnected {
                // A safety net in case the domain wasn't disconnected by the app
                self.disconnectDomainDueToSignOut()
            }
        }
    }

    private static func isMenuBarAppIdentified(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return bundleIdentifier.hasSuffix("ch.protonmail.drive") // may or may not have team ID as prefix
    }

    private func disconnectDomainDueToMenuBarAppNotRunning() {
        Log.event(.domainConnectionChanged(.started(.init(
            domainIdentifier: domain.identifier.rawValue,
            isConnected: !domain.isDisconnected,
            reason: .appStoppedRunning
        ))))
        manager.disconnect(reason: "Proton Drive needs to be running in order to sync these files.", options: .temporary) { error in
            if let error {
                Log.event(.domainConnectionChanged(.failed(.init(
                    id: self.domain.identifier.rawValue,
                    error: error
                ))))
            } else {
                Log.event(.domainConnectionChanged(.succeeded(.init(
                    domainIdentifier: self.domain.identifier.rawValue,
                    isConnected: !self.domain.isDisconnected,
                    reason: .appStoppedRunning
                ))))
            }
        }
    }

    private func disconnectDomainDueToSignOut() {
        Log.event(.domainConnectionChanged(.started(.init(
            domainIdentifier: domain.identifier.rawValue,
            isConnected: !domain.isDisconnected,
            reason: .signedOut
        ))))
        manager.disconnect(reason: "Sign in required.", options: .temporary) { error in
            if let error {
                Log.event(.domainConnectionChanged(.failed(.init(
                    id: self.domain.identifier.rawValue,
                    error: error
                ))))
            } else {
                Log.event(.domainConnectionChanged(.succeeded(.init(
                    domainIdentifier: self.domain.identifier.rawValue,
                    isConnected: !self.domain.isDisconnected,
                    reason: .signedOut
                ))))
            }
        }
    }

    private func connectDomainDueToMenuBarAppRunning() {
        Log.event(.domainConnectionChanged(.started(.init(
            domainIdentifier: domain.identifier.rawValue,
            isConnected: !domain.isDisconnected,
            reason: .appStartedRunning
        ))))
        guard cacheReset != true else {
            Log.event(.domainConnectionChanged(.failed(.init(
                id: self.domain.identifier.rawValue,
                errorMessage: "cacheReset"
            ))))
            return
        }
        manager.reconnect { error in
            if let error {
                Log.event(.domainConnectionChanged(.failed(.init(
                    id: self.domain.identifier.rawValue,
                    error: error
                ))))
            } else {
                Log.event(.domainConnectionChanged(.succeeded(.init(
                    domainIdentifier: self.domain.identifier.rawValue,
                    isConnected: !self.domain.isDisconnected,
                    reason: .appStartedRunning
                ))))
            }
        }
    }
    
    private func stopObservingRunningAppChanges() {
        Log.info("Stop observing app running changes", domain: .application)
        self.observer?.invalidate()
        self.observer = nil
    }

    private func startObservingNetworkState() {
        networkCancellable = tower.connectionStateResource.state
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .unreachable:
                    Log.info("Network offline — cancelling operations", domain: .fileProvider)
                    self.progresses.cancelAll(reason: .networkOffline)
                case .reachable:
                    Log.info("Network online — file provider will retry operations", domain: .fileProvider)
                }
            }
    }
}

// MARK: - Enumerations - called by NSFileProvider

extension FileProviderExtension {
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator
    {
        Log.trace()
        do {
            Log.event(.enumerator(.started(.init(containerType: .init(containerItemIdentifier),
                                                  eventSource: .init(request)))))

            let context = tower.storage.synchronousContextPool.acquire()
            defer { tower.storage.synchronousContextPool.relinquish(context) }
            guard let rootID = tower.rootFolderIdentifier(moc: context) else {
                Log.event(.enumerator(.failed(.init(
                    containerType: .init(containerItemIdentifier),
                    errorMessage: "Enumerator for \(containerItemIdentifier) cannot be provided because there is no rootID"
                ))))
                throw Errors.rootNotFound
            }

            switch containerItemIdentifier {
            case .workingSet:
                let wse = WorkingSetEnumerator(tower: tower,
                                               keepDownloadedManager: keepDownloadedManager,
                                               enumerationObserver: enumerationObserver,
                                               displayChangeEnumerationDetails: RuntimeConfiguration.shared.includeChangeEnumerationDetailsInTrayApp,
                                               shouldReenumerateItems: shouldReenumerateItems == true)
                shouldReenumerateItems = false
                Log.event(.enumerator(.succeeded(.init(containerType: .init(containerItemIdentifier)))))
                return wse
                
            case .trashContainer:
                let te = TrashEnumerator(tower: tower,
                                         keepDownloadedManager: keepDownloadedManager,
                                         enumerationObserver: enumerationObserver,
                                         displayChangeEnumerationDetails: RuntimeConfiguration.shared.includeChangeEnumerationDetailsInTrayApp)
                Log.event(.enumerator(.succeeded(.init(containerType: .init(containerItemIdentifier)))))
                return te

            case .rootContainer:
                let re = RootEnumerator(tower: tower,
                                        keepDownloadedManager: keepDownloadedManager,
                                        rootID: rootID,
                                        enumerationObserver: enumerationObserver,
                                        displayEnumeratedItems: RuntimeConfiguration.shared.includeItemEnumerationDetailsInTrayApp,
                                        shouldReenumerateItems: shouldReenumerateItems == true)
                Log.event(.enumerator(.succeeded(.init(containerType: .init(containerItemIdentifier)))))
                return re
                
            default:
                guard let nodeId = NodeIdentifier(rawValue: containerItemIdentifier.rawValue) else {
                    Log.event(.enumerator(.failed(.init(
                        containerType: .init(containerItemIdentifier),
                        errorMessage: "Could not find NodeID for folder enumerator"
                    ))))
                    throw NSFileProviderError(NSFileProviderError.Code.noSuchItem)
                }
                let fe = FolderEnumerator(tower: tower,
                                          keepDownloadedManager: keepDownloadedManager,
                                          nodeID: nodeId,
                                          enumerationObserver: enumerationObserver,
                                          displayEnumeratedItems: RuntimeConfiguration.shared.includeItemEnumerationDetailsInTrayApp,
                                          shouldReenumerateItems: shouldReenumerateItems == true)
                Log.event(.enumerator(.succeeded(.init(containerType: .init(containerItemIdentifier)))))
                return fe
            }
        } catch {
            Log.event(.enumerator(.failed(.init(
                containerType: .init(containerItemIdentifier),
                error: error
            ))))
            throw error.mapToFileProviderError()
        }
    }
}

// MARK: Items metadata and contents - called by NSFileProvider

extension FileProviderExtension {
    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if RecoveryCoordination.isInProgress {
            Log.info("item(for:) call exited early due to recovery in progress", domain: .fileProvider)
            completionHandler(nil, CocoaError(.userCancelled))
            return Progress()
        }

        tower.storage.reloadStoreIfReplacedByMainApp()
        Log.event(.fetchItem(.started(.init(itemID: identifier.logIdentifier, parentIDs: tower.parentIDFetcher.fetchParentIDs(for: identifier.logIdentifier), eventSource: .init(request)))))
        Log.trace()
        return fileProviderOperations.item(for: identifier,
                                           request: request,
                                           completionHandler: completionHandler)
    }
    
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        if RecoveryCoordination.isInProgress {
            Log.info("fetchContents call exited early due to recovery in progress", domain: .fileProvider)
            completionHandler(nil, nil, CocoaError(.userCancelled))
            return Progress()
        }

        tower.storage.reloadStoreIfReplacedByMainApp()
        Log.trace()
        Log.event(.fetchContents(.started(.init(itemID: itemIdentifier.logIdentifier, parentIDs: tower.parentIDFetcher.fetchParentIDs(for: itemIdentifier.logIdentifier), expectedVersion: requestedVersion?.sha256))))
        return fileProviderOperations.fetchContents(itemIdentifier: itemIdentifier,
                                                    requestedVersion: requestedVersion,
                                                    completionHandler: completionHandler)
    }
}

// MARK: Actions on items - called by NSFileProvider

// swiftlint:disable function_parameter_count
extension FileProviderExtension {
    
    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress
    {
        if RecoveryCoordination.isInProgress {
            Log.info("createItem call exited early due to recovery in progress", domain: .fileProvider)
            completionHandler(nil, [], false, CocoaError(.userCancelled))
            return Progress()
        }

        tower.storage.reloadStoreIfReplacedByMainApp()
        Log.event(.createItem(.started(.init(
            itemID: itemTemplate.itemIdentifier.logIdentifier,
            parentIDs: [itemTemplate.parentItemIdentifier.logIdentifier] + tower.parentIDFetcher.fetchParentIDs(for: itemTemplate.parentItemIdentifier.logIdentifier),
            isFolder: itemTemplate.isFolder,
            hasContents: url != nil,
            eventSource: .init(request),
            options: .init(options)
        ))))
        return fileProviderOperations.createItem(basedOn: itemTemplate,
                                                 fields: fields,
                                                 contents: url,
                                                 options: options,
                                                 request: request,
                                                 completionHandler: completionHandler)
    }
    
    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress
    {
        if RecoveryCoordination.isInProgress {
            Log.info("modifyItem call exited early due to recovery in progress", domain: .fileProvider)
            completionHandler(nil, [], false, CocoaError(.userCancelled))
            return Progress()
        }

        tower.storage.reloadStoreIfReplacedByMainApp()
        Log.event(.modifyItem(.started(.init(
            itemID: item.itemIdentifier.logIdentifier,
            parentIDs: tower.parentIDFetcher.fetchParentIDs(for: item.itemIdentifier.logIdentifier),
            eventSource: .init(request),
            hasContents: newContents != nil,
            changedFields: .init(changedFields),
            options: .init(options),
            version: version.sha256
        ))))
        let customCompletionHandler: (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void = { item, fields, shouldFetchContent, error in
            completionHandler(item, fields, shouldFetchContent, error)
            
            // Update keep downloaded if item moved
            if changedFields.contains(.parentItemIdentifier), let item {
                self.updateKeepDownloaded(for: item)
            }
        }
            return fileProviderOperations.modifyItem(item,
                                                     baseVersion: version,
                                                     changedFields: changedFields,
                                                     contents: newContents,
                                                     options: options,
                                                     request: request,
                                                     completionHandler: customCompletionHandler)
        }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress
    {
        if RecoveryCoordination.isInProgress {
            Log.info("deleteItem call exited early due to recovery in progress", domain: .fileProvider)
            completionHandler(CocoaError(.userCancelled))
            return Progress()
        }

        tower.storage.reloadStoreIfReplacedByMainApp()
        Log.event(.deleteItem(.started(.init(
            itemID: identifier.logIdentifier,
            parentIDs: tower.parentIDFetcher.fetchParentIDs(for: identifier.logIdentifier),
            isRecursive: options.contains(.recursive),
            eventSource: .init(request),
            version: version.sha256
        ))))
        return fileProviderOperations.deleteItem(identifier: identifier,
                                                 baseVersion: version,
                                                 options: options,
                                                 request: request,
                                                 completionHandler: completionHandler)
    }
    
    /// Called when the user triggers the "Refresh" action in Finder.
    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        
        Log.trace(actionIdentifier.rawValue)
        
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)
        
        let moc = tower.storage.backgroundContext
        
        switch actionIdentifier.rawValue {
        case "ch.protonmail.drive.fileprovider.action.keep_downloaded":
            Log.info("performAction keep_downloaded for \(itemIdentifiers.count) item(s)", domain: .offlineAvailable)
            return enableKeepDownloaded(itemsWithIdentifiers: itemIdentifiers, moc: moc, completionBlockWrapper: completionBlockWrapper)
        case "ch.protonmail.drive.fileprovider.action.remove_download":
            Log.info("performAction remove_download for \(itemIdentifiers.count) item(s)", domain: .offlineAvailable)
            return removeDownload(itemsWithIdentifiers: itemIdentifiers, moc: moc, completionBlockWrapper: completionBlockWrapper)
        case "ch.protonmail.drive.fileprovider.action.refresh":
            return forceRefresh(identifier: actionIdentifier, itemsWithIdentifiers: itemIdentifiers, moc: moc, completionHandler: completionHandler)
        case "ch.protonmail.drive.fileprovider.action.open_in_browser":
            return openInBrowser(identifier: actionIdentifier, itemsWithIdentifiers: itemIdentifiers, moc: moc, completionHandler: completionHandler)
        default:
            assertionFailure("Unexpected action received")
            completionBlockWrapper(nil)
            return .init(totalUnitCount: 0)
        }
    }
    
    private func enableKeepDownloaded(itemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                                      moc: NSManagedObjectContext,
                                      completionBlockWrapper: CompletionBlockWrapper<Error?, Void, Void, Void>) -> Progress {
        return setKeepDownloaded(true,
                                 itemsWithIdentifiers: itemIdentifiers,
                                 moc: moc,
                                 completionBlockWrapper: completionBlockWrapper)
    }
    
    private func removeDownload(itemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                                moc: NSManagedObjectContext,
                                completionBlockWrapper: CompletionBlockWrapper<Error?, Void, Void, Void>) -> Progress {
        return setKeepDownloaded(false,
                                 itemsWithIdentifiers: itemIdentifiers,
                                 moc: moc,
                                 completionBlockWrapper: completionBlockWrapper)
    }
    
    private func setKeepDownloaded(_ keepDownloaded: Bool,
                                   itemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                                   moc: NSManagedObjectContext,
                                   completionBlockWrapper: CompletionBlockWrapper<Error?, Void, Void, Void>? = nil) -> Progress {
        keepDownloadedManager.setKeepDownloadedState(to: keepDownloaded, for: itemIdentifiers, moc: moc)
        
        completionBlockWrapper?(nil)
        return .init(totalUnitCount: 0)
    }
    
    // Used to update keep downloaded state in response to non-direct action from the user
    // (e.g. moving a folder into another that has been marked available offline)
    private func updateKeepDownloaded(for item: NSFileProviderItem) {
        let moc = tower.storage.backgroundContext
        let nodeIdentifier: NodeIdentifier?
        if item.itemIdentifier == NSFileProviderItemIdentifier.rootContainer ||
            item.itemIdentifier == NSFileProviderItemIdentifier.workingSet,
           let nodeId = tower.rootFolderIdentifier(moc: moc) {
            nodeIdentifier = nodeId
        } else {
            nodeIdentifier = NodeIdentifier(item.itemIdentifier)
        }
        
        guard let nodeIdentifier else { return }
        
        guard let node = tower.fileSystemSlot.getNode(nodeIdentifier, moc: moc) else { return }
        
        keepDownloadedManager.updateStateBasedOnParent(for: [node], moc: moc)
    }
    
    func forceRefresh(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                      itemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                      moc: NSManagedObjectContext,
                      completionHandler: @escaping (Error?) -> Void) -> Progress {
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)
        
        guard !isForceRefreshing else {
            completionBlockWrapper(nil)
            return .init(unitsOfWork: 0)
        }
        
        Log.info("Force refresh action handling started", domain: .enumerating)
        
        syncReporter.refreshStarted()
        
        isForceRefreshing = true
        
        let foldersToScan = itemIdentifiers.compactMap { self.folderForItemIdentifier($0, moc: moc) }
        
        let progress: Progress = .init(unitsOfWork: foldersToScan.count)
        
        do {
            let itemOperation = try tower.downloader.scanTrees(treesRootFolders: foldersToScan) { node in
                Log.debug("Scanned node \(node.id)", domain: .enumerating)
            } completion: { [weak self] result in
                self?.progresses.remove(progress)
                guard progress.isCancelled != true else {
                    completionBlockWrapper(CocoaError(.userCancelled))
                    return
                }
                progress.complete()
                self?.syncReporter.refreshFinished()
                self?.finalizeScanningTrees(result, completionBlockWrapper)
            }
            progress.addChild(itemOperation.progress, pending: itemOperation.progress.pendingUnitsOfWork)
        } catch {
            if !itemIdentifiers.contains(.rootContainer) {
                isForceRefreshing = false
                return performAction(identifier: actionIdentifier, onItemsWithIdentifiers: [.rootContainer], completionHandler: completionHandler)
            }
        }
        
        progresses.add(progress)
        return progress
    }
    
    func openInBrowser(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       itemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       moc: NSManagedObjectContext,
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)
        
        Log.debug("Open in browser: \(itemIdentifiers)", domain: .enumerating)
        
        let itemIdentifiersToOpen: [String] = itemIdentifiers.compactMap {
            // find node for identifier
            guard let nodeIdentifier = NodeIdentifier($0),
                  let node = tower.fileSystemSlot.getNode(nodeIdentifier, moc: moc) else {
                return nil
            }
            
            if node.isFolder == true {
                // for folders, return identifier directly
                return node.identifier.id
            } else {
                // for files, return the parent folder identifier
                return node.parentNode?.identifier.id
            }
        }
        
        // Updating UserDefault observed by the app.
        self.openItemsInBrowser = itemIdentifiersToOpen.joined(separator: ",")
        
        completionBlockWrapper(nil)
        return Progress(unitsOfWork: 0)
    }
}

// MARK: - Refresh action

extension FileProviderExtension: NSFileProviderCustomAction {

    private func finalizeScanningTrees(_ result: Result<[Node], Error>,
                                       _ completionBlockWrapper: CompletionBlockWrapper<Error?, Void, Void, Void>) {
        switch result {
        case .success(let nodes):
            guard let first = nodes.first, let moc = first.moc else {
                Log.error("Refreshing cancelled because node has no moc", domain: .fileProvider)
                completionBlockWrapper(CocoaError(.userCancelled))
                return
            }
            let deletedNodes = moc.performAndWait {
                nodes.filter { $0.state == .deleted }
            }
            let dispatchGroup = DispatchGroup()
            deletedNodes
                .map { NSFileProviderItemIdentifier($0.identifier.rawValue) }
                .forEach { identifier in
                    dispatchGroup.enter()
                    manager.evictItem(identifier: identifier) { _ in
                        // error is ignored as this is a disk space optimization, not required for the feature to work
                        dispatchGroup.leave()
                    }
                }
            dispatchGroup.notify(queue: .main) { [weak self] in
                guard let self else {
                    completionBlockWrapper(CocoaError(.userCancelled))
                    return
                }
                self.isForceRefreshing = false

                self.shouldReenumerateItems = true
                Log.event(.signalEnumerator(.started(.init(containerType: .workingSet, reason: .forceRefresh))))
                self.manager.signalEnumerator(for: .workingSet) { error in
                    if let error {
                        Log.event(.signalEnumerator(.failed(.init(
                            id: NSFileProviderItemIdentifier.workingSet.logIdentifier, error: error
                        ))))
                    } else {
                        Log.event(.signalEnumerator(.succeeded(.init(
                            containerType: .workingSet, reason: .forceRefresh
                        ))))
                    }
                    Log.info("Force refresh action ended", domain: .enumerating)
                    completionBlockWrapper(error)
                }
            }
        case .failure(let error):
            isForceRefreshing = false
            shouldReenumerateItems = false
            Log.info("Force refresh action ended", domain: .enumerating)
            completionBlockWrapper(error)
        }
    }
    
    private func folderForItemIdentifier(_ itemIdentifier: NSFileProviderItemIdentifier, moc: NSManagedObjectContext) -> Folder? {
        let nodeIdentifier: PDCore.NodeIdentifier
        if let nodeId = NodeIdentifier(rawValue: itemIdentifier.rawValue) {
            nodeIdentifier = nodeId
        } else if itemIdentifier == NSFileProviderItemIdentifier.rootContainer
                    || itemIdentifier == NSFileProviderItemIdentifier.workingSet,
                  let nodeId = tower.rootFolderIdentifier(moc: moc) {
            nodeIdentifier = nodeId
        } else {
            return nil
        }
        return tower.folderForNodeIdentifier(nodeIdentifier, moc: moc)
    }
}

// swiftlint:enable function_parameter_count
