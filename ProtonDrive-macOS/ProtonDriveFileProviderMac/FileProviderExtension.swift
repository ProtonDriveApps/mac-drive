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
import FileProvider
import PDCore
import PDClient
import PDFileProvider
import ProtonCoreLog
import ProtonCoreCryptoGoInterface
import ProtonCoreUtilities
import PDUploadVerifier
import ProtonCoreCryptoMultiversionPatchedGoImplementation
import PDFileProviderOperations
import PMEventsManager

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    @SettingsStorage(UserDefaults.FileProvider.workingSetEnumerationInProgressKey.rawValue) var workingSetEnumerationInProgress: Bool?
    @SettingsStorage(UserDefaults.FileProvider.shouldReenumerateItemsKey.rawValue) var shouldReenumerateItems: Bool?
    @SettingsStorage("domainDisconnectedReasonCacheReset") public var cacheReset: Bool?
    @SettingsStorage(UserDefaults.FileProvider.isKeepDownloadedEnabledKey.rawValue) var isKeepDownloadedEnabledAccordingToExtension: Bool?
    @SettingsStorage(UserDefaults.FileProvider.pathsMarkedAsKeepDownloadedKey.rawValue) var pathsMarkedAsKeepDownloaded: String?
    @SettingsStorage(UserDefaults.FileProvider.pathsMarkedAsOnlineOnlyKey.rawValue) var pathsMarkedAsOnlineOnly: String?
    @SettingsStorage(UserDefaults.FileProvider.openItemsInBrowserKey.rawValue) var openItemsInBrowser: String?
    @SettingsStorage(UserDefaults.FileProvider.extensionPathKey.rawValue) var fileProviderExtensionPath: String?

    #if HAS_QA_FEATURES
    @SettingsStorage("driveDDKEnabledInQASettings") var driveDDKEnabledInQASettings: Bool?
    #endif
    
    private var isDDKEnabled: Bool {
        #if arch(x86_64)
            return isDDKEnabledOnIntel
        #else
            return isDDKEnabledOnAppleSilicon
        #endif
    }
    
    private var isDDKEnabledOnAppleSilicon: Bool {
        #if HAS_QA_FEATURES
            if driveDDKEnabledInQASettings == false {
                return false
            }
        #endif

        if tower.featureFlags.isEnabled(flag: .driveDDKDisabled) {
            return false
        }

        return true
    }
    
    private var isDDKEnabledOnIntel: Bool {
        #if HAS_QA_FEATURES
            if driveDDKEnabledInQASettings == false {
                return false
            }
        #endif

        if tower.featureFlags.isEnabled(flag: .driveDDKDisabled) {
            return false
        }

        guard tower.featureFlags.isEnabled(flag: .driveDDKIntelEnabled) else {
            return false
        }

        return true
    }

    private var isKeepDownloadedEnabled: Bool {
        tower.featureFlags.isEnabled(flag: .driveMacKeepDownloadedDisabled) != true
    }

    private var domainSettings: DomainSettings

    private var isForceRefreshing: Bool = false
    
    private let domain: NSFileProviderDomain // use domain to support multiple accounts
    private let manager: NSFileProviderManager
    
    private var observer: NSKeyValueObservation?
    
    var tower: Tower { postLoginServices.tower }

    private lazy var syncReporter = SyncReporter(tower: tower, manager: manager)
    
    private var fileProviderOperations: FileProviderOperationsProtocol!
    private var progresses = FileOperationProgresses()
    
    private lazy var itemProvider = ItemProvider()
    private lazy var keymaker = DriveKeymaker(autolocker: nil, keychain: DriveKeychain.shared,
                                              logging: { Log.info($0, domain: .storage) })

    private var enumerationObserver: EnumerationObserver!

    private let instanceIdentifier = UUID()

    private lazy var initialServices = InitialServices(
        userDefault: Constants.appGroup.userDefaults,
        clientConfig: Constants.userApiConfig,
        mainKeyProvider: keymaker,
        autoLocker: nil,
        sessionRelatedCommunicatorFactory: { sessionStore, authenticator, onSessionReceived in
            SessionRelatedCommunicatorForExtension(
                userDefaultsConfiguration: .forFileProviderExtension(userDefaults: Constants.appGroup.userDefaults),
                sessionStorage: sessionStore,
                childSessionKind: .fileProviderExtension,
                onChildSessionObtained: onSessionReceived
            )
        }
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
        storage: tower.storage,
        fileSystemSlot: tower.fileSystemSlot,
        fileProviderManager: manager
    )

    private let observationCenter: PDCore.UserDefaultsObservationCenter

    required init(domain: NSFileProviderDomain) {
        inject(cryptoImplementation: ProtonCoreCryptoMultiversionPatchedGoImplementation.CryptoGoMethodsImplementation.instance)
        // Inject build type to enable build differentiation. (Build macros don't work in SPM)
        PDCore.Constants.buildType = Constants.buildType

        // the logger setup happens before the super.init, hence the captured `client` and `featureFlags` variables
        var featureFlags: PDCore.FeatureFlagsRepository?
        Constants.loadConfiguration()
        FileProviderExtension.configureCoreLogger()
        FileProviderExtension.setupLogger { featureFlags }
        Log.debug("Init with domain \(domain.identifier)", domain: .fileProvider)
        
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
            fatalError("File provider manager is required by the file provider extension to operate")
        }
        self.manager = manager
        updateLastLineBeforeHanging()
        
        _shouldReenumerateItems.configure(with: Constants.appGroup)
        _openItemsInBrowser.configure(with: Constants.appGroup)
        _cacheReset.configure(with: Constants.appGroup)
        _fileProviderExtensionPath.configure(with: Constants.appGroup)
        updateLastLineBeforeHanging()

        domainSettings = LocalSettings.shared
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
        
        guard tower.rootFolderAvailable() else {
            Log.error("No root folder means the database was not bootstrapped yet by the main app. Disconnect the domain until the app reconnects it.", error: nil, domain: .fileProvider)
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
        tower.sessionVault.consumeChildSessionCredentials(kind: .fileProviderExtension)
        updateLastLineBeforeHanging()
        tower.sessionVault.consumeChildSessionCredentials(kind: .ddk)
        updateLastLineBeforeHanging()
        
        self.clearDrafts()
        updateLastLineBeforeHanging()
        
        Log.info("FileProviderExtension init: \(instanceIdentifier.uuidString)", domain: .syncing)
        updateLastLineBeforeHanging()
        
        self.tower.start(options: [])
        updateLastLineBeforeHanging()
        
        self.startObservingRunningAppChanges()
        updateLastLineBeforeHanging()

        self.syncReporter.cleanUpOnLaunch()
        updateLastLineBeforeHanging()
        
        self.setUpKeepDownloadedObservers()
        updateLastLineBeforeHanging()
        let hasKeepDownloadedStateChanged = handleKeepDownloadedStateChange()
        updateLastLineBeforeHanging()
        
        self.reenumerateIfNecessary(hasKeepDownloadedStateChanged: hasKeepDownloadedStateChanged)
        updateLastLineBeforeHanging()

        postExtensionLaunchNotification()
        updateLastLineBeforeHanging()
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
                Log.trace("Found \(itemIdentifiers.count) itemIdentifiers to keep downloaded")
                for itemIdentifier in itemIdentifiers {
                    Log.trace("Marking as \"Available offline\": \(itemIdentifier)")
                    _ = self?.setKeepDownloaded(true, itemsWithIdentifiers: itemIdentifiers)
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
                Log.trace("Found \(itemIdentifiers.count) itemIdentifiers to mark as online only")
                for itemIdentifier in itemIdentifiers {
                    Log.trace("Marking as \"Online only\": \(itemIdentifier)")
                    _ = self?.setKeepDownloaded(false, itemsWithIdentifiers: itemIdentifiers)
                }
            }
        }
    }

    private func setUpFileProviderOperations() {
#if HAS_QA_FEATURES
        _driveDDKEnabledInQASettings.configure(with: Constants.appGroup)
#endif

        if isDDKEnabled {
            Log.info("Starting FileProviderExtension with DDK", domain: .fileProvider)
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                self.fileProviderOperations = await DDKFileProviderOperations(
                    tower: tower,
                    sessionCommunicatorUserDefaults: Constants.appGroup.userDefaults,
                    syncReporter: syncReporter,
                    itemProvider: itemProvider,
                    manager: manager,
                    downloadCollector: DBPerformanceMeasurementCollector(operationType: .download),
                    uploadCollector: DBPerformanceMeasurementCollector(operationType: .upload),
                    progresses: progresses,
                    enableRegressionTestHelpers: RuntimeConfiguration.shared.enableTestAutomation,
                    ignoreSslCertificateErrors: RuntimeConfiguration.shared.ignoreDdkSslCertificateErrors
                )
                semaphore.signal()
            }
            semaphore.wait()
        } else {
            Log.info("Starting FileProviderExtension without DDK", domain: .fileProvider)
            self.fileProviderOperations = LegacyFileProviderOperations(
                tower: tower,
                syncReporter: syncReporter,
                itemProvider: itemProvider,
                manager: manager,
                progresses: progresses,
                enableRegressionTestHelpers: RuntimeConfiguration.shared.enableTestAutomation,
                downloadCollector: DBPerformanceMeasurementCollector(operationType: .download),
                uploadCollector: DBPerformanceMeasurementCollector(operationType: .upload)
            )
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
                    client.deleteRevision(identifier.revision, identifier.file, shareID: identifier.share) { _ in
                        // The result is ignored because deleting revision draft is not strictly required.
                        // * the revision will be cleared after 4 hours by backend's collector
                        // * (once it's implemented) during the revision upload, if the draft revision already exists and its uploadClientUID
                        //   matches the new revision, we will delete the revision draft as we do delete the file draft
                    }
                },
                includingAlreadyUploadedFiles: true)
            if draftWasCleared {
                manager.signalEnumerator(for: .workingSet) { error in
                    guard let error else { return }
                    Log.error("Failed to signal enumerator after clearing drafts",
                              error: error, domain: .enumerating)
                }
            }
        } catch {
            Log.error("Failed to clear drafts", error: error, domain: .storage)
        }
    }

    private func reenumerateIfNecessary(hasKeepDownloadedStateChanged: Bool) {
        if shouldReenumerateItems == true || workingSetEnumerationInProgress == true || hasKeepDownloadedStateChanged == true {
            manager.signalEnumerator(for: .workingSet) { [weak self] error in
                guard let error else { return }
                let sei = self?.shouldReenumerateItems.map(\.description) ?? "nil"
                let wseip = self?.workingSetEnumerationInProgress.map(\.description) ?? "nil"
                Log.error("Failed to signal enumerator due to shouldReenumerateItems \(sei) or workingSetEnumerationInProgress \(wseip): \(error.localizedDescription)",
                          domain: .enumerating)
            }
        }
    }

    private func handleKeepDownloadedStateChange() -> Bool {
        let oldState = isKeepDownloadedEnabledAccordingToExtension ?? false
        let newState = tower.featureFlags.isEnabled(flag: .driveMacKeepDownloadedDisabled) != true

        if oldState != newState {
            isKeepDownloadedEnabledAccordingToExtension = newState
            initialServices.localSettings.bumpDomainVersion()

            return true
        } else {
            return false
        }
    }

    deinit {
        observationCenter.removeObserver(self)
        Log.info("FileProviderExtension deinit: \(instanceIdentifier.uuidString)", domain: .syncing)
    }
    
    private static func configureCoreLogger() {
        PMLog.setExternalLoggerHost(Constants.userApiConfig.environment.doh.defaultHost)
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
        Log.debug("Invalidate with domain \(domain.identifier)", domain: .fileProvider)
        stopObservingRunningAppChanges()
        tower.stop()
        tower.sessionCommunicator.stopObservingSessionChanges()
        progresses.invalidateProgresses()
        syncReporter.cleanUpOnInvalidate()

        // Attempt to send any outstanding metrics before FileProvider is killed
        flushDDKObservalibilityServiceAndWait()
    }

    private func flushDDKObservalibilityServiceAndWait() {
        guard let ddkFileProviderOperations = fileProviderOperations as? DDKFileProviderOperations else { return }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await ddkFileProviderOperations.flushObservabilityService()
            semaphore.signal()
        }
        semaphore.wait()
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
            let isSignedIn = self.tower.rootFolderAvailable()
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
        Log.info("Will display banner informing that app is not running", domain: .application)
        manager.disconnect(reason: "Proton Drive needs to be running in order to sync these files.", options: .temporary) { error in
            Log.info("Did display banner informing that app is not running", domain: .application)
            guard let error else { return }
            Log
                .error(
                    "File provider failed to disconnect domain when app stopped running",
                    error: error,
                    domain: .fileProvider
                )
        }
    }

    private func disconnectDomainDueToSignOut() {
        Log.info("Will display banner informing that app is not running due to sign out", domain: .application)
        manager.disconnect(reason: "Sign in required.", options: .temporary) { error in
            Log.info("Did display banner informing that app is not running due to sign out", domain: .application)
            guard let error else { return }
            Log
                .error(
                    "File provider failed to disconnect domain due to sign out",
                    error: error,
                    domain: .fileProvider
                )
        }
    }

    private func connectDomainDueToMenuBarAppRunning() {
        guard cacheReset != true else { return }
        
        Log.info("Will dismiss banner informing that app is not running", domain: .application)
        manager.reconnect { error in
            Log.info("Did dismiss banner informing that app is not running", domain: .application)
            guard let error else { return }
            Log
                .error(
                    "File provider failed to reconnect domain when app started running",
                    error: error,
                    domain: .fileProvider
                )
        }
    }
    
    private func stopObservingRunningAppChanges() {
        Log.info("Stop observing app running changes", domain: .application)
        self.observer?.invalidate()
        self.observer = nil
    }
}

// MARK: - Enumerations - called by NSFileProvider

extension FileProviderExtension {
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator
    {
        Log.trace()
        do {
            Log.info("Provide enumerator for \(containerItemIdentifier)", domain: .enumerating)

            guard let rootID = tower.rootFolderIdentifier() else {
                Log.info("Enumerator for \(containerItemIdentifier) cannot be provided because there is no rootID", domain: .enumerating)
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
                return wse
                
            case .trashContainer:
                return TrashEnumerator(tower: tower,
                                       keepDownloadedManager: keepDownloadedManager,
                                       enumerationObserver: enumerationObserver,
                                       displayChangeEnumerationDetails: RuntimeConfiguration.shared.includeChangeEnumerationDetailsInTrayApp)

            case .rootContainer:
                let re = RootEnumerator(tower: tower,
                                        keepDownloadedManager: keepDownloadedManager,
                                        rootID: rootID,
                                        enumerationObserver: enumerationObserver,
                                        displayEnumeratedItems: RuntimeConfiguration.shared.includeItemEnumerationDetailsInTrayApp,
                                        shouldReenumerateItems: shouldReenumerateItems == true)
                return re
                
            default:
                guard let nodeId = NodeIdentifier(rawValue: containerItemIdentifier.rawValue) else {
                    Log.error("Could not find NodeID for folder enumerator", domain: .enumerating)
                    throw NSFileProviderError(NSFileProviderError.Code.noSuchItem)
                }
                let fe = FolderEnumerator(tower: tower,
                                          keepDownloadedManager: keepDownloadedManager,
                                          nodeID: nodeId,
                                          enumerationObserver: enumerationObserver,
                                          displayEnumeratedItems: RuntimeConfiguration.shared.includeItemEnumerationDetailsInTrayApp,
                                          shouldReenumerateItems: shouldReenumerateItems == true)
                return fe
            }
        } catch {
            throw PDFileProvider.Errors.mapToFileProviderError(error)
        }
    }
}

// MARK: Items metadata and contents - called by NSFileProvider

extension FileProviderExtension {
    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {

        Log.trace()
        return fileProviderOperations.item(for: identifier,
                                           request: request,
                                           completionHandler: completionHandler)
    }
    
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        Log.trace()
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
        Log.trace()
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
        Log.trace()
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
        Log.trace()
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
        
        switch actionIdentifier.rawValue {
        case "ch.protonmail.drive.fileprovider.action.keep_downloaded":
            return enableKeepDownloaded(itemsWithIdentifiers: itemIdentifiers, completionBlockWrapper: completionBlockWrapper)
        case "ch.protonmail.drive.fileprovider.action.remove_download":
            return removeDownload(itemsWithIdentifiers: itemIdentifiers, completionBlockWrapper: completionBlockWrapper)
        case "ch.protonmail.drive.fileprovider.action.refresh":
            return forceRefresh(identifier: actionIdentifier, itemsWithIdentifiers: itemIdentifiers, completionHandler: completionHandler)
        case "ch.protonmail.drive.fileprovider.action.open_in_browser":
            return openInBrowser(identifier: actionIdentifier, itemsWithIdentifiers: itemIdentifiers, completionHandler: completionHandler)
        default:
            assertionFailure("Unexpected action received")
            completionBlockWrapper(nil)
            return .init(totalUnitCount: 0)
        }
    }
    
    private func enableKeepDownloaded(itemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                                      completionBlockWrapper: CompletionBlockWrapper<Error?, Void, Void, Void>) -> Progress {
        return setKeepDownloaded(true,
                                 itemsWithIdentifiers: itemIdentifiers,
                                 completionBlockWrapper: completionBlockWrapper)
    }
    
    private func removeDownload(itemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                                completionBlockWrapper: CompletionBlockWrapper<Error?, Void, Void, Void>) -> Progress {
        return setKeepDownloaded(false,
                                 itemsWithIdentifiers: itemIdentifiers,
                                 completionBlockWrapper: completionBlockWrapper)
    }
    
    private func setKeepDownloaded(_ keepDownloaded: Bool,
                                   itemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                                   completionBlockWrapper: CompletionBlockWrapper<Error?, Void, Void, Void>? = nil) -> Progress {
        keepDownloadedManager.setKeepDownloadedState(to: keepDownloaded, for: itemIdentifiers)
        
        completionBlockWrapper?(nil)
        return .init(totalUnitCount: 0)
    }
    
    // Used to update keep downloaded state in response to non-direct action from the user
    // (e.g. moving a folder into another that has been marked available offline)
    private func updateKeepDownloaded(for item: NSFileProviderItem) {
        let nodeIdentifier: NodeIdentifier?
        if item.itemIdentifier == NSFileProviderItemIdentifier.rootContainer ||
            item.itemIdentifier == NSFileProviderItemIdentifier.workingSet,
           let nodeId = tower.rootFolderIdentifier() {
            nodeIdentifier = nodeId
        } else {
            nodeIdentifier = NodeIdentifier(item.itemIdentifier)
        }
        
        guard let nodeIdentifier else { return }
        
        let moc = tower.storage.backgroundContext
        guard let node = tower.fileSystemSlot.getNode(nodeIdentifier, moc: moc) else { return }
        
        keepDownloadedManager.updateStateBasedOnParent(for: [node])
    }
    
    func forceRefresh(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                      itemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                      completionHandler: @escaping (Error?) -> Void) -> Progress {
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)
        
        guard !isForceRefreshing else {
            completionBlockWrapper(nil)
            return .init(unitsOfWork: 0)
        }
        
        Log.info("Force refresh action handling started", domain: .enumerating)
        
        syncReporter.refreshStarted()
        
        isForceRefreshing = true
        
        let foldersToScan = itemIdentifiers.compactMap(self.folderForItemIdentifier)
        
        let progress: Progress = .init(unitsOfWork: foldersToScan.count)
        
        do {
            let itemOperation = try tower.downloader.scanTrees(treesRootFolders: foldersToScan) { node in
                Log.debug("Scanned node \(node.decryptedName)", domain: .enumerating)
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
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)
        
        Log.debug("Open in browser: \(itemIdentifiers)", domain: .enumerating)
        let moc = tower.storage.backgroundContext
        
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
                self.manager.signalEnumerator(for: .workingSet) { error in
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
    
    private func folderForItemIdentifier(_ itemIdentifier: NSFileProviderItemIdentifier) -> Folder? {
        let nodeIdentifier: PDCore.NodeIdentifier
        if let nodeId = NodeIdentifier(rawValue: itemIdentifier.rawValue) {
            nodeIdentifier = nodeId
        } else if itemIdentifier == NSFileProviderItemIdentifier.rootContainer
                    || itemIdentifier == NSFileProviderItemIdentifier.workingSet,
                  let nodeId = tower.rootFolderIdentifier() {
            nodeIdentifier = nodeId
        } else {
            return nil
        }
        return tower.folderForNodeIdentifier(nodeIdentifier)
    }
}

// swiftlint:enable function_parameter_count

extension FileProviderExtension: NSFileProviderDomainState {
    public var domainVersion: NSFileProviderDomainVersion {
        domainSettings.domainVersion
    }

    // Used to enable/disable actions defined in `info.plist`
    public var userInfo: [AnyHashable: Any] {
        return ["keepDownloadedEnabled": isKeepDownloadedEnabled]
    }
}
