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
import Foundation
import PDCore
import PDClient
import PDFileProvider
import PDLoadTesting
import ProtonCoreLog
import ProtonCoreKeymaker
import ProtonCoreFeatureFlags
import ProtonCoreCryptoPatchedGoImplementation
import ProtonCoreUtilities
import PDUploadVerifier
import Combine

#if LOAD_TESTING && SSL_PINNING
#error("Load testing requires turning off SSL pinning, so it cannot be set for SSL-pinning targets")
#endif

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    
    @SettingsStorage(UserDefaults.Key.shouldReenumerateItemsKey.rawValue) var shouldReenumerateItems: Bool?
    @SettingsStorage("domainDisconnectedReasonCacheReset") public var cacheReset: Bool?
    
    private var isForceRefreshing: Bool = false
    
    let domain: NSFileProviderDomain // use domain to support multiple accounts
    let manager: NSFileProviderManager
    
    private var observer: NSKeyValueObservation?
    
    var tower: Tower { postLoginServices.tower }
    var syncStorage: SyncStorageManager {
        postLoginServices.tower.syncStorage ?? SyncStorageManager(suite: Constants.appGroup)
    }
    var downloader: SuspendableDownloader { SuspendableDownloader(downloader: tower.downloader) }
    var fileUploader: SuspendableFileUploader { SuspendableFileUploader(uploader: tower.fileUploader, progress: nil) }
    private lazy var itemProvider = ItemProvider()
    private lazy var itemActionsOutlet = ItemActionsOutlet(fileProviderManager: manager)
    private lazy var keymaker = DriveKeymaker(autolocker: nil, keychain: DriveKeychain.shared,
                                              logging: { Log.info($0, domain: .storage) })

    private lazy var changeObserver = SyncChangeObserver()

    var syncReportingController: SyncReporting {
        SyncReportingController(storage: syncStorage, suite: Constants.appGroup, appTarget: .fileProviderExtension)
    }
    
    private var progresses: Atomic<[Progress]> = .init([])
    private let instanceIdentifier = UUID()

    private lazy var initialServices = InitialServices(userDefault: Constants.appGroup.userDefaults,
                                                       clientConfig: Constants.userApiConfig,
                                                       keymaker: keymaker,
                                                       sessionRelatedCommunicatorFactory: SessionRelatedCommunicatorForExtension.init)

    private lazy var postLoginServices = PostLoginServices(
        initialServices: initialServices, 
        appGroup: Constants.appGroup, 
        eventObservers: [], 
        eventProcessingMode: .processRecords, 
        uploadVerifierFactory: ConcreteUploadVerifierFactory(),
        activityObserver: { [weak self] activity in
            self?.currentActivityChanged(activity)
        }
    )
    
    required init(domain: NSFileProviderDomain) {
        injectDefaultCryptoImplementation()
        // Inject build type to enable build differentiation. (Build macros don't work in SPM)
        PDCore.Constants.buildType = Constants.buildType

        #if LOAD_TESTING && !SSL_PINNING
        LoadTesting.enableLoadTesting()
        #endif

        // the logger setup happens before the super.init, hence the captured `client` and `featureFlags` variables
        var client: PDClient.Client?
        var featureFlags: PDCore.FeatureFlagsRepository?
        Constants.loadConfiguration()
        FileProviderExtension.configureCoreLogger()
        FileProviderExtension.setupLogger { featureFlags } clientGetter: { client }
        Log.debug("Init with domain \(domain.identifier)", domain: .fileProvider)
        self.domain = domain
        guard let manager = NSFileProviderManager(for: domain) else {
            fatalError("File provider manager is required by the file provider extension to operate")
        }
        self.manager = manager
        
        _shouldReenumerateItems.configure(with: Constants.appGroup)
        _cacheReset.configure(with: Constants.appGroup)
        
        #if LOAD_TESTING
        Log.info("LOAD_TESTING: YES", domain: .fileProvider)
        Log.info("HOST: \(Constants.userApiConfig.baseHost)", domain: .fileProvider)
        #else
        Log.info("LOAD_TESTING: NO", domain: .fileProvider)
        #endif
        
        super.init()
        
        // expose the client and featureFlags to logger
        client = tower.client
        featureFlags = tower.featureFlags
        
        guard tower.rootFolderAvailable() else {
            fatalError("No root folder means the database was not bootstrap yet by the main app. There is no point in running file provider at all.")
        }
        // this line covers a rare scenario in which the child session credentials
        // were fetched and saved to keychain by the main app, but file provider extension
        // somehow did not get informed about them through the user defaults.
        // the one confirmed case of this scenario happening was when user denied access
        // to group container on the Sequoia, so the user defaults were not available
        tower.sessionVault.consumeChildSessionCredentials()
        
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
                    Log.error("Failed to signal enumerator after clearing drafts: \(error.localizedDescription)",
                              domain: .storage)
                }
            }
        } catch {
            Log.error("Failed to clear drafts: \(error.localizedDescription)", domain: .storage)
        }
        
        Log.info("FileProviderExtension init: \(instanceIdentifier.uuidString)", domain: .syncing)
        
        self.tower.start(options: [])
        self.startObservingRunningAppChanges()
        if let syncStorage = tower.syncStorage {
            let oldItemsRelativeDate = syncStorage.oldItemsRelativeDate
            do {
                try self.syncReportingController.cleanSyncItems(olderThan: oldItemsRelativeDate)
            } catch {
                Log.error("Failed to clean sync errors: \(error.localizedDescription)", domain: .syncing)
            }
        }
    }
    
    deinit {
        Log.info("FileProviderExtension deinit: \(instanceIdentifier.uuidString)", domain: .syncing)
    }
    
    private static func configureCoreLogger() {
        let environment: String
        switch Constants.userApiConfig.environment {
        case .black, .blackPayment: environment = "black"
        case .custom(let custom): environment = custom
        default: environment = "production"
        }
        PMLog.setEnvironment(environment: environment)
    }

    private static func setupLogger(featureFlagsGetter: @escaping () -> PDCore.FeatureFlagsRepository?,
                                    clientGetter: @escaping () -> PDClient.Client?) {
        let localSettings = LocalSettings(suite: Constants.appGroup)
        SentryClient.shared.start(localSettings: localSettings, clientGetter: clientGetter)
        Log.configuration = LogConfiguration(system: .macOSFileProvider)
        #if LOAD_TESTING
        Log.logger = CompoundLogger(loggers: [
            OrFilteredLogger(logger: DebugLogger(),
                             domains: [.loadTesting],
                             levels: [.info, .error, .warning]),
            FileLogger(process: .macOSFileProvider) {
                featureFlagsGetter()?.isEnabled(flag: .logsCompressionDisabled) ?? false
            }
        ])
        #elseif PRODUCTION_LEVEL_LOGS
        Log.logger = CompoundLogger(loggers: [
            ProductionLogger(),
            OrFilteredLogger(logger: FileLogger(process: .macOSFileProvider) {
                featureFlagsGetter()?.isEnabled(flag: .logsCompressionDisabled) ?? false
            }, levels: [.info, .error, .warning])
        ])
        #else
        Log.logger = CompoundLogger(loggers: [
            OrFilteredLogger(logger: DebugLogger(),
                             domains: [.application,
                                       .encryption,
                                       .events,
                                       .networking,
                                       .uploader,
                                       .downloader,
                                       .storage,
                                       .clientNetworking,
                                       .featureFlags,
                                       .forceRefresh,
                                       .sessionManagement,
                                       .diagnostics,
                                       .fileProvider,
                                       .fileManager],
                             levels: [.info, .error, .warning]),
            FileLogger(process: .macOSFileProvider) {
                featureFlagsGetter()?.isEnabled(flag: .logsCompressionDisabled) ?? false
            }
        ])
        #endif
        PDClient.log = { Log.info($0, domain: .clientNetworking) }
        #if HAS_QA_FEATURES
        DarwinNotificationCenter.shared.addObserver(self, for: .SendErrorEventToTestSentry) { _ in
            let originalLogger = Log.logger
            // Temporarily replace logger to test Sentry events sending
            Log.logger = ProductionLogger()
            let error = NSError(domain: "FILEPROVIDER SENTRY TESTING", code: 0, localizedDescription: "Test from file provider")
            Log.error(error.localizedDescription, domain: .fileProvider)
            // Restore original logger after the test
            Log.logger = originalLogger
        }
        DarwinNotificationCenter.shared.addObserver(self, for: .DoCrashToTestSentry) { _ in
            fatalError("FileProvider: Forced crash to test Sentry crash reporting")
        }
        #endif

        NotificationCenter.default.addObserver(forName: .NSApplicationProtectedDataDidBecomeAvailable, object: nil, queue: nil) { notificaiton in
            Log.info("Notification.Name.NSApplicationProtectedDataDidBecomeAvailable", domain: .fileProvider)
        }
        NotificationCenter.default.addObserver(forName: .NSApplicationProtectedDataWillBecomeUnavailable, object: nil, queue: nil) { notificaiton in
            Log.info("Notification.Name.NSApplicationProtectedDataWillBecomeUnavailable", domain: .fileProvider)
        }
    }
    
    func invalidate() {
        Log.debug("Invalidate with domain \(domain.identifier)", domain: .fileProvider)
        stopObservingRunningAppChanges()
        tower.stop()
        tower.sessionCommunicator.stopObservingSessionChanges()
        downloader.invalidateOperations()
        fileUploader.invalidateOperations()
        invalidateProgress()
        cleanUpSyncStorageAfterInvalidate()
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
        self.observer = NSWorkspace.shared
            .observe(\.runningApplications, options: [.initial, .new, .old],
                      changeHandler: { [weak self] in self?.runningAppsChangeHandler($0, $1) })
    }
    
    private func runningAppsChangeHandler(_ workspace: NSWorkspace, _ change: NSKeyValueObservedChange<[NSRunningApplication]>) {
        let wasRunning: Bool
        let running: Bool

        if let oldValue = change.oldValue, oldValue.contains(where: { isMenuBarAppIdentified($0.bundleIdentifier) }) {
            wasRunning = true
        } else {
            wasRunning = false
        }

        if let newValue = change.newValue, newValue.contains(where: { isMenuBarAppIdentified($0.bundleIdentifier) }) {
            running = true
        } else {
            running = false
        }

        if wasRunning && !running {
            menuBarAppStoppedRunning()
        } else if !wasRunning && running {
            menuBarAppStartedRunning()
        }
    }
    
    private func isMenuBarAppIdentified(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return bundleIdentifier.hasSuffix("ch.protonmail.drive") // may or may not have team ID as prefix
    }

    private func menuBarAppStoppedRunning() {
        Log.info("Will display banner informing that app is not running", domain: .application)
        self.manager.disconnect(reason: "Proton Drive needs to be running in order to sync these files.", options: .temporary, completionHandler: { error in
            Log.info("Did display banner informing that app is not running", domain: .application)
            guard let error else { return }
            Log.error("File provider failed to disconnect domain when app stopped running, error: \(error.localizedDescription)", domain: .fileProvider)
        })
    }

    private func menuBarAppStartedRunning() {
        guard cacheReset != true else { return }

        Log.info("Will dismiss banner informing that app is not running", domain: .application)
        self.manager.reconnect(completionHandler: { error in
            Log.info("Did dismiss banner informing that app is not running", domain: .application)
            guard let error else { return }
            Log.error("File provider failed to disconnect domain when app stopped running, error: \(error.localizedDescription)", domain: .fileProvider)
        })
    }

    private func stopObservingRunningAppChanges() {
        Log.info("Stop observing app running changes", domain: .application)
        self.observer?.invalidate()
        self.observer = nil
    }
}

// MARK: Progress management and cancellation

extension FileProviderExtension {
    func addProgress(progress: Progress?) {
        progresses.mutate { if let progress { $0.append(progress) } }
    }
    
    func removeProgress(progress: Progress?) {
        progresses.mutate { if let progress { $0 = $0.removing(progress) } }
    }
    
    func invalidateProgress() {
        progresses.mutate {
            $0.forEach { $0.cancel() }
            $0.removeAll()
        }
    }
}

// MARK: Enumerations

extension FileProviderExtension {
    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator
    {
        do {
            Log.info("Provide enumerator for \(containerItemIdentifier)", domain: .application)
            
            guard let rootID = tower.rootFolderIdentifier() else {
                Log.info("Enumerator for \(containerItemIdentifier) cannot be provided because there is no rootID", domain: .application)
                throw Errors.rootNotFound
            }

            switch containerItemIdentifier {
            case .workingSet:
                let wse = WorkingSetEnumerator(tower: tower, changeObserver: changeObserver,
                                               shouldReenumerateItems: shouldReenumerateItems == true)
                shouldReenumerateItems = false
                return wse
                
            case .trashContainer:
                return TrashEnumerator(tower: tower, changeObserver: changeObserver)
                
            case .rootContainer:
                let re = RootEnumerator(tower: tower, rootID: rootID, changeObserver: changeObserver,
                                        shouldReenumerateItems: shouldReenumerateItems == true)
                shouldReenumerateItems = false
                return re
                
            default:
                guard let nodeId = NodeIdentifier(containerItemIdentifier) else {
                    Log.error("Could not find NodeID for folder enumerator", domain: .fileProvider)
                    throw NSFileProviderError(NSFileProviderError.Code.noSuchItem)
                }
                let fe = FolderEnumerator(tower: tower, changeObserver: changeObserver, nodeID: nodeId,
                                          shouldReenumerateItems: shouldReenumerateItems == true)
                shouldReenumerateItems = false
                return fe
            }
        } catch {
            throw PDFileProvider.Errors.mapToFileProviderError(error) ?? error
        }
    }
}

// MARK: Items metadata and contents

extension FileProviderExtension {

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        changeObserver.incrementSyncCounter()
        let creatorsIfRoot = identifier == .rootContainer ? tower.sessionVault.addressIDs : []
        // wrapper is used because we leak the passed completion block on operation cancellation, so we need to ensure
        // that the system-provided completion block (which retains extension instance) is not leaked after being called
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)
        var itemProgress: Progress?
        let progress = itemProvider.item(
            for: identifier, creatorAddresses: creatorsIfRoot, slot: tower.fileSystemSlot!
        ) { [weak self] item, error in
            self?.changeObserver.decrementSyncCounter(type: .pull, error: error)
            
            itemProgress?.clearOneTimeCancellationHandler()
            self?.removeProgress(progress: itemProgress)
            guard itemProgress?.isCancelled != true else {
                completionBlockWrapper(item, error)
                return
            }
            
            let fpError = PDFileProvider.Errors.mapToFileProviderError(error)
            completionBlockWrapper(item, fpError)
        }
        itemProgress = progress
        addProgress(progress: progress)
        return progress
    }
    
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress
    {
        changeObserver.incrementSyncCounter()
        // wrapper is used because we leak the passed completion block on operation cancellation, so we need to ensure
        // that the system-provided completion block (which retains extension instance) is not leaked after being called
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)
        var fetchContentsProgress: Progress?
        self.forward(itemIdentifier: itemIdentifier, operation: .fetchContents, changedFields: [])
        
        var completionAlreadyCalled = false // See comment below
        let progress = itemProvider.fetchContents(
            for: itemIdentifier, version: requestedVersion, slot: tower.fileSystemSlot!, downloader: tower.downloader!, storage: tower.storage
        ) { [weak self] url, item, error in
            guard !completionAlreadyCalled else {
                // This is a temporary fix for the fact that downloadAndDecrypt(...) will call us again from
                // its completion handler for scheduleDownloadFileProvider() after a network error.
                // For some reason it thinks the call succeeded but then understandably fails to get the revision and calls back into here.
                
                // This was the cause of decrementSyncCounter sometimes having unmatched sync counts due to the double call
                
                // Someone with better understanding of what is going on should look into this further.
                Log.error("Completion Handler for \(#function) was already called. Ignoring secondary call.", domain: .syncing)
                return
            }
            completionAlreadyCalled = true
            
            self?.changeObserver.decrementSyncCounter(type: .pull, error: error)
            
            fetchContentsProgress?.clearOneTimeCancellationHandler()
            self?.removeProgress(progress: fetchContentsProgress)
            guard fetchContentsProgress?.isCancelled != true else {
                completionBlockWrapper(url, item, error)
                return
            }
            
            self?.reconcile(itemIdentifier: itemIdentifier, possibleError: error, during: .fetchContents)
            let fpError = PDFileProvider.Errors.mapToFileProviderError(error)
            completionBlockWrapper(url, item, fpError)
        }
        fetchContentsProgress = progress
        addProgress(progress: progress)
        return progress
    }
}

// MARK: Actions on items

// swiftlint:disable function_parameter_count
extension FileProviderExtension {
    
    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress
    {
        changeObserver.incrementSyncCounter()
        // wrapper is used because we leak the passed completion block on operation cancellation, so we need to ensure
        // that the system-provided completion block (which retains extension instance) is not leaked after being called
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)
        var createItemProgress: Progress?
        self.forward(item: itemTemplate, operation: .create, changedFields: fields)
        let progress = itemActionsOutlet.createItem(
            tower: tower, basedOn: itemTemplate, fields: fields, contents: url, options: options, request: request
        ) { [weak self] item, fields, needUpload, error in
            self?.changeObserver.decrementSyncCounter(type: .push, error: error)
            
            createItemProgress?.clearOneTimeCancellationHandler()
            self?.removeProgress(progress: createItemProgress)
            guard createItemProgress?.isCancelled != true else {
                completionBlockWrapper(item, fields, needUpload, error)
                return
            }
            
            self?.reconcile(item: item ?? itemTemplate, possibleError: error, during: .create, changedFields: fields, temporaryItem: itemTemplate)
            let fpError = PDFileProvider.Errors.mapToFileProviderError(error)
            completionBlockWrapper(item, fields, needUpload, fpError)
        }
        createItemProgress = progress
        addProgress(progress: progress)
        return progress
    }
    
    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress
    {
        // wrapper is used because we leak the passed completion block on operation cancellation, so we need to ensure
        // that the system-provided completion block (which retains extension instance) is not leaked after being called
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)
        var modifyItemProgress: Progress?
        self.forward(item: item, operation: .modify, changedFields: changedFields)
        let progress = self.itemActionsOutlet.modifyItem(
            tower: tower, item: item, baseVersion: version, changedFields: changedFields, contents: newContents,
            options: options, request: request, changeObserver: changeObserver
        ) { [weak self] modifiedItem, fields, needUpload, error in
            
            modifyItemProgress?.clearOneTimeCancellationHandler()
            self?.removeProgress(progress: modifyItemProgress)
            guard modifyItemProgress?.isCancelled != true else {
                completionBlockWrapper(modifiedItem, fields, needUpload, error)
                return
            }
            
            self?.reconcile(item: item, possibleError: error, during: .modify, changedFields: changedFields)
            let fpError = PDFileProvider.Errors.mapToFileProviderError(error)
            completionBlockWrapper(modifiedItem, fields, needUpload, fpError)
        }
        modifyItemProgress = progress
        addProgress(progress: progress)
        return progress
    }
    
    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress
    {
        changeObserver.incrementSyncCounter()
        // wrapper is used because we leak the passed completion block on operation cancellation, so we need to ensure
        // that the system-provided completion block (which retains extension instance) is not leaked after being called
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)
        var deleteItemProgress: Progress?
        self.forward(itemIdentifier: identifier, operation: .delete, changedFields: [])
        let progress = self.itemActionsOutlet.deleteItem(
            tower: tower, identifier: identifier, baseVersion: version, options: options, request: request
        ) { [weak self] error in
            self?.changeObserver.decrementSyncCounter(type: .push, error: error)
            
            deleteItemProgress?.clearOneTimeCancellationHandler()
            self?.removeProgress(progress: deleteItemProgress)
            guard deleteItemProgress?.isCancelled != true else {
                completionBlockWrapper(error)
                return
            }
            
            self?.reconcile(itemIdentifier: identifier, possibleError: error, during: .delete)
            let fpError = PDFileProvider.Errors.mapToFileProviderError(error)
            completionBlockWrapper(fpError)
        }
        deleteItemProgress = progress
        addProgress(progress: progress)
        return progress
    }
    
}

extension FileProviderExtension: NSFileProviderCustomAction {
    
    func performAction(identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
                       onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
                       completionHandler: @escaping (Error?) -> Void) -> Progress {
        
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)

        guard actionIdentifier.rawValue == "ch.protonmail.drive.fileprovider.action.refresh" else {
            assertionFailure("Unexpected action received")
            completionBlockWrapper(nil)
            return .init(totalUnitCount: 0)
        }
        
        guard !isForceRefreshing else {
            completionBlockWrapper(nil)
            return .init(unitsOfWork: 0)
        }
        
        Log.info("Force refresh action handling started", domain: .forceRefresh)
        
        isForceRefreshing = true
        
        let foldersToScan = itemIdentifiers.compactMap(self.folderForItemIdentifier)
        
        let progress: Progress = .init(unitsOfWork: foldersToScan.count)
        
        let itemOperation = tower.downloader.scanTrees(treesRootFolders: foldersToScan) { node in
            Log.debug("Scanned node \(node.decryptedName)", domain: .forceRefresh)
        } completion: { [weak self] result in
            self?.removeProgress(progress: progress)
            guard progress.isCancelled != true else {
                completionBlockWrapper(CocoaError(.userCancelled))
                return
            }
            progress.complete()
            self?.finalizeScanningTrees(result, completionBlockWrapper)
        }
        
        progress.addChild(itemOperation.progress, pending: itemOperation.progress.pendingUnitsOfWork)
        
        addProgress(progress: progress)
        
        return progress
    }
    
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
                .map { NSFileProviderItemIdentifier($0.identifier) }
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
                    Log.info("Force refresh action ended", domain: .forceRefresh)
                    completionBlockWrapper(error)
                }
            }
        case .failure(let error):
            isForceRefreshing = false
            shouldReenumerateItems = false
            Log.info("Force refresh action ended", domain: .forceRefresh)
            completionBlockWrapper(error)
        }
    }
    
    private func folderForItemIdentifier(_ itemIdentifier: NSFileProviderItemIdentifier) -> Folder? {
        let nodeIdentifier: NodeIdentifier
        if let nodeId = NodeIdentifier(itemIdentifier) {
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
