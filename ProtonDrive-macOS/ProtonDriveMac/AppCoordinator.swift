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

import SwiftUI
import FileProvider
import PDFileProvider
import ProtonCoreFeatureFlags
import ProtonCoreKeymaker
import ProtonCoreLogin
import ProtonCoreNetworking
import ProtonCoreUtilities
import ProtonCoreUIFoundations
import PDClient
import PDCore
import PDLogin_macOS
import Combine

class AppCoordinator: NSObject, ObservableObject {
    
    @SettingsStorage(UserDefaults.Key.shouldReenumerateItemsKey.rawValue) var shouldReenumerateItems: Bool?
    @SettingsStorage(UserDefaults.Key.hasPostMigrationStepRunKey.rawValue) var hasPostMigrationStepRun: Bool?

    enum SignInStep {
        case login
        case initialization
        case onboarding
    }
    
    private let initialServices: InitialServices
    private let networkStateService: NetworkStateInteractor
    private let driveCoreAlertListener: DriveCoreAlertListener
    private let loginBuilder: LoginManagerBuilder
    private var login: LoginManager?
    private var settings: SettingsCoordinator?
    private var syncErrors: ErrorCoordinator?
    #if HAS_QA_FEATURES
    private var qaSettings: QASettingsCoordinator?
    #endif
    private let postLoginServicesBuilder: PostLoginServicesBuilder
    private var postLoginServices: PostLoginServices?
    private let metadataMonitorBuilder: MetadataMonitorBuilder
    private let logContentLoader: LogContentLoader
    private var metadataMonitor: MetadataMonitor?
    private var activityService: ActivityService?
    private let launchOnBoot: any LaunchOnBootServiceProtocol
    let domainOperationsService: DomainOperationsService

    #if HAS_BUILTIN_UPDATER
    private let appUpdateService: any AppUpdateServiceProtocol
    #endif

    private var communicationService: CoreDataCommunicationService<SyncItem>?

    private var syncStateService: SyncStateService

    private(set) var window: NSWindow?

    private var screen: SignInStep?

    private var menuBarCoordinator: MenuBarCoordinator?
    private var syncCoordinator: SyncCoordinator?
    private var initializationCoordinator: InitializationCoordinator?
    private var onboardingCoordinator: OnboardingCoordinator?

    var client: PDClient.Client? {
        postLoginServices?.tower.client
    }
    
    var featureFlags: PDCore.FeatureFlagsRepository? {
        postLoginServices?.tower.featureFlags
    }
    
    private var isLoggingOut: Atomic<Bool> = .init(false)

    private var menuSyncErrorsCount: Int {
        guard let metadataMonitor, let syncStorage = metadataMonitor.syncStorage else {
            return 0
        }
        return syncStorage.syncErrorsCount(in: syncStorage.mainContext)
    }

    override convenience init() {
        let keymaker = DriveKeymaker(autolocker: nil, keychain: DriveKeychain.shared,
                                     logging: { Log.info($0, domain: .storage) })
        let initialServices = InitialServices(userDefault: Constants.appGroup.userDefaults,
                                              clientConfig: Constants.userApiConfig,
                                              keymaker: keymaker,
                                              sessionRelatedCommunicatorFactory: SessionRelatedCommunicatorForMainApp.init)
        let networkStateService = ConnectedNetworkStateInteractor(resource: MonitoringNetworkStateResource())
        networkStateService.execute()
        let syncStateService = SyncStateService()
        let driveCoreAlertListener = DriveCoreAlertListener(client: initialServices.networkClient)
        let loginBuilder = ConcreteLoginManagerBuilder(
            environment: Constants.userApiConfig.environment,
            apiServiceDelegate: initialServices.networkClient,
            forceUpgradeDelegate: initialServices.networkClient)
        let postLoginServicesBuilder = ConcretePostLoginServicesBuilder(initialServices: initialServices, eventProcessingMode: .pollAndRecord)
        let observationCenter = PDCore.UserDefaultsObservationCenter(userDefaults: Constants.appGroup.userDefaults)
        let metadataMonitorBuilder = ConcreteMetadataMonitorBuilder(observationCenter: observationCenter)
        let logContentLoader = FileLogContent()
        let launchOnBoot = LaunchOnBootLegacyAPIService()
        var featureFlagsAccessor: () -> PDCore.FeatureFlagsRepository? = { nil }
        let domainOperationsService = DomainOperationsService(
            accountInfoProvider: initialServices.sessionVault,
            featureFlags: { featureFlagsAccessor() },
            fileProviderManagerFactory: SystemFileProviderManagerFactory())
        #if HAS_BUILTIN_UPDATER
        let appUpdateService = SparkleAppUpdateService()
        self.init(initialServices: initialServices,
                  networkStateService: networkStateService, 
                  syncStateService: syncStateService,
                  driveCoreAlertListener: driveCoreAlertListener,
                  loginBuilder: loginBuilder,
                  postLoginServicesBuilder: postLoginServicesBuilder,
                  metadataMonitorBuilder: metadataMonitorBuilder,
                  logContentLoader: logContentLoader,
                  launchOnBoot: launchOnBoot,
                  appUpdateService: appUpdateService,
                  domainOperationsService: domainOperationsService)
#else
        self.init(initialServices: initialServices,
                  networkStateService: networkStateService,
                  syncStateService: syncStateService,
                  driveCoreAlertListener: driveCoreAlertListener,
                  loginBuilder: loginBuilder,
                  postLoginServicesBuilder: postLoginServicesBuilder,
                  metadataMonitorBuilder: metadataMonitorBuilder,
                  logContentLoader: logContentLoader,
                  launchOnBoot: launchOnBoot,
                  domainOperationsService: domainOperationsService)
#endif
        featureFlagsAccessor = { [weak self] in self?.featureFlags }
    }

#if HAS_BUILTIN_UPDATER
    required init(initialServices: InitialServices,
                  networkStateService: NetworkStateInteractor,
                  syncStateService: SyncStateService,
                  driveCoreAlertListener: DriveCoreAlertListener,
                  loginBuilder: LoginManagerBuilder,
                  postLoginServicesBuilder: PostLoginServicesBuilder,
                  metadataMonitorBuilder: MetadataMonitorBuilder,
                  logContentLoader: LogContentLoader,
                  launchOnBoot: any LaunchOnBootServiceProtocol,
                  appUpdateService: any AppUpdateServiceProtocol,
                  domainOperationsService: DomainOperationsService) {
        self.initialServices = initialServices
        self.networkStateService = networkStateService
        self.syncStateService = syncStateService
        self.driveCoreAlertListener = driveCoreAlertListener
        self.loginBuilder = loginBuilder
        self.postLoginServicesBuilder = postLoginServicesBuilder
        self.metadataMonitorBuilder = metadataMonitorBuilder
        self.logContentLoader = logContentLoader
        self.launchOnBoot = launchOnBoot
        self.appUpdateService = appUpdateService
        self.domainOperationsService = domainOperationsService
        super.init()
        sharedInitSetup()
    }
#else
    required init(initialServices: InitialServices,
                  networkStateService: NetworkStateInteractor,
                  syncStateService: SyncStateService,
                  driveCoreAlertListener: DriveCoreAlertListener,
                  loginBuilder: LoginManagerBuilder,
                  postLoginServicesBuilder: PostLoginServicesBuilder,
                  metadataMonitorBuilder: MetadataMonitorBuilder,
                  logContentLoader: LogContentLoader,
                  launchOnBoot: any LaunchOnBootServiceProtocol,
                  domainOperationsService: DomainOperationsService) {
        self.initialServices = initialServices
        self.networkStateService = networkStateService
        self.syncStateService = syncStateService
        self.driveCoreAlertListener = driveCoreAlertListener
        self.loginBuilder = loginBuilder
        self.postLoginServicesBuilder = postLoginServicesBuilder
        self.metadataMonitorBuilder = metadataMonitorBuilder
        self.logContentLoader = logContentLoader
        self.launchOnBoot = launchOnBoot
        self.domainOperationsService = domainOperationsService
        super.init()
        sharedInitSetup()
    }
#endif
    
    private func sharedInitSetup() {
        _shouldReenumerateItems.configure(with: Constants.appGroup)
        _hasPostMigrationStepRun.configure(with: Constants.appGroup)
        #if HAS_QA_FEATURES
        NotificationCenter.default.addObserver(forName: .fileProviderDomainStateDidChange, object: nil, queue: nil) { notification in
            guard let domainDisconnected = notification.userInfo?["domainDisconnected"] as? Bool else { return }
            Task {
                try await self.changeCurrentDomainState(domainDisconnected: domainDisconnected)
            }
        }
        #endif
    }
    
    private func fetchFeatureFlags() async {
        do {
            try await initialServices.featureFlagsRepository.fetchFlags()
        } catch {
            Log.error("Could not retrieve feature flags: \(error)", domain: .featureFlags)
        }
    }
    
    @MainActor
    func start() async throws {
        #if HAS_BUILTIN_UPDATER
        self.menuBarCoordinator = MenuBarCoordinator(delegate: self,
                                                     loggedInStateReporter: self.initialServices,
                                                     appUpdaterService: self.appUpdateService,
                                                     networkStateService: self.networkStateService,
                                                     syncStateService: self.syncStateService,
                                                     domainOperationsService: self.domainOperationsService)
        #else
        self.menuBarCoordinator = MenuBarCoordinator(delegate: self,
                                                     loggedInStateReporter: self.initialServices,
                                                     networkStateService: self.networkStateService,
                                                     syncStateService: self.syncStateService,
                                                     domainOperationsService: self.domainOperationsService)
        #endif
        if self.initialServices.isLoggedIn {
            Log.info("AppCoordinator start - logged in", domain: .application)
            
            try await domainOperationsService.identifyDomain()

            await fetchFeatureFlags()

            let postLoginServices = preparePostLoginServices()
            
            try await postLoginServices.tower.cleanUpLockedVolumeIfNeeded(using: domainOperationsService)

            // error fetching feature flags should not cause the login process to fail, we will use the default values
            try? await FeatureFlagsRepository.shared.fetchFlags()
            try? await postLoginServices.tower.featureFlags.startAsync()

            if try await !domainOperationsService.domainExists() {
                await postLoginServices.tower.cleanUpEventsAndMetadata(cleanupStrategy: .cleanEverything)
            }
            try await postLoginServices.tower.bootstrapIfNeeded()
            var wasRefreshingNodes = false
            if domainOperationsService.hasDomainReconnectionCapability {
                // we're after boostrap, so TBH if there's no root, I'd question my sanity (or suspect some other thread deleting it from under me)
                guard let root = try? postLoginServices.tower.rootFolder() else { throw Errors.rootNotFound }
                // if there are dirty nodes in DB, it means the previous run hasn't finished successfully
                let hasDirtyNodes = try await postLoginServices.tower.refresher.hasDirtyNodes(root: root)
                if hasDirtyNodes {
                    await postLoginServices.tower.refresher.sendRefreshNotFinishedSentryEvent(root: root)
                    try await refreshUsingDirtyNodesApproach(tower: postLoginServices.tower, root: root)
                    wasRefreshingNodes = true
                }
            }

            // ignore the error because it's handled withing the method
            do {
                try await startPostLoginServices(postLoginServices: postLoginServices)
            } catch {
                // we ignore the error because it's handled internally in startPostLoginServices
                return
            }
            menuBarCoordinator?.featureFlags = self.featureFlags
            if wasRefreshingNodes {
                shouldReenumerateItems = true
                try await domainOperationsService.signalEnumerator()
            }
            if Constants.isInUITests {
                await configureForUITests()
            }
        } else {
            Log.info("AppCoordinator start - not logged in", domain: .application)
            if Constants.isInUITests {
                await configureForUITests()
                await showLogin()
            } else {
                await showLogin()
            }

            configureDocumentController(with: nil)
        }
    }
    
    func signOutAsync() async {
        await postLoginServices?.signOutAsync(domainOperationsService: domainOperationsService)
        didLogout()
    }

    #if HAS_QA_FEATURES
    func changeCurrentDomainState(domainDisconnected: Bool) async throws {
        guard let tower = postLoginServices?.tower else { return }
        
        if domainDisconnected {
            menuBarCoordinator?.cacheRefreshSyncState = .syncing
            do {
                try await refreshUsingDirtyNodesApproach(tower: tower)
            } catch {
                if case PDFileProvider.Errors.rootNotFound = error {
                    // if there's no root, we must re-bootstrap
                    try await tower.bootstrap()
                    try await refreshUsingDirtyNodesApproach(tower: tower)
                } else {
                    menuBarCoordinator?.cacheRefreshSyncState = .synced
                    throw error
                }
            }
            
            menuBarCoordinator?.cacheRefreshSyncState = .synced

            try await domainOperationsService.connectDomain()
            domainOperationsService.cacheReset = false

            shouldReenumerateItems = true
            try await domainOperationsService.signalEnumerator()
        } else {
            let migrationPerformer = MigrationPerformer()
            try await domainOperationsService.disconnectDomainsTemporarily(
                reason: { $0.map { "\($0.displayName) domain disconnected" } ?? "" }
            )
            menuBarCoordinator?.cacheRefreshSyncState = .syncing
            try await migrationPerformer.performCleanup(in: tower)
            menuBarCoordinator?.cacheRefreshSyncState = .synced
        }
    }
    #endif

    private func refreshUsingEagerSyncApproach(tower: Tower) async throws {
        guard let rootFolder = try? tower.rootFolder() else {
            throw Errors.rootNotFound
        }
        
        let coordinator = await showInitialization()
        
        do {
            coordinator.update(progress: .init())
            
            try await tower.refresher.refreshUsingEagerSyncApproach(root: rootFolder) { identifier in
                try await domainOperationsService.evictItem(identifier: identifier)
            }
        } catch {
            coordinator.showFailure(error: error) { [weak self] in
                try await self?.refreshUsingEagerSyncApproach(tower: tower)
            }
        }
    }
    
    private func refreshUsingDirtyNodesApproach(tower: Tower, root: Folder? = nil, retrying: Bool = false) async throws {
        guard let rootFolder = try? root ?? tower.rootFolder() else {
            throw Errors.rootNotFound
        }
        
        let coordinator = await showInitialization()
        coordinator.update(progress: .init(totalValue: 1))
        
        do {
            try await tower.refresher.refreshUsingDirtyNodesApproach(root: rootFolder, resumingOnRetry: retrying) { current, total in
                Task { @MainActor in
                    let progress = InitializationProgress(currentValue: current, totalValue: total)
                    self.initializationCoordinator?.update(progress: progress)
                }
            } evictItem: {
                try await domainOperationsService.evictItem(identifier: $0)
            }
        } catch {
            // this cannot just return, because we will go on to the onboarding
            try await withCheckedThrowingContinuation { continuation in
                coordinator.showFailure(error: error) { [weak self] in
                    try await self?.refreshUsingDirtyNodesApproach(tower: tower, root: rootFolder, retrying: true)
                    continuation.resume()
                }
            }
        }
    }

    func showLogin(initialError: LoginError? = nil) async {
        self.screen = .login
        await MainActor.run {
            if let login = self.login {
                login.presentLoginFlow(
                    with: initialError ?? self.driveCoreAlertListener.initialLoginError()
                )
            } else {
                let appWindow = createWindow()
                self.window = appWindow

                let login = self.loginBuilder.build(in: appWindow) { [weak self] result in
                    guard let self = self else { return }

                    self.processLoginResult(result)
                }

                self.login = login
                login.presentLoginFlow(
                    with: initialError ?? self.driveCoreAlertListener.initialLoginError()
                )
            }
        }
    }

    func showOnboarding() {
        initializationCoordinator = nil
        
        screen = .onboarding
        
        Task { @MainActor in
            let window = retrieveAlreadyPresentedWindow()
            onboardingCoordinator = OnboardingCoordinator(window: window)
            onboardingCoordinator?.start()
        }
    }
    
    private func retrieveAlreadyPresentedWindow() -> NSWindow {
        if let window {
            return window
        } else {
            Log.error("Could not retrieve window, creating a new one", domain: .application)
            let newWindow = createWindow()
            self.window = newWindow
            presentWindow()
            return newWindow
        }
    }
    
    private func createWindow() -> NSWindow {
        let appWindow = NSWindow()
        appWindow.styleMask = [.titled, .closable, .miniaturizable]
        appWindow.titlebarAppearsTransparent = true
        appWindow.backgroundColor = ColorProvider.BackgroundNorm
        appWindow.delegate = self
        appWindow.isReleasedWhenClosed = false
        return appWindow
    }
    
    private func presentWindow() {
        guard let window else { return }
        let origin: CGPoint = .init(
            x: NSScreen.main.map { $0.visibleFrame.maxX / 10.0 } ?? 50.0,
            y: NSScreen.main.map { $0.visibleFrame.maxY / 10.0 } ?? 50.0
        )
        window.setFrame(NSRect(origin: origin, size: CGSize(width: 420, height: 480)),
                        display: true)
        window.level = .statusBar
        window.makeKeyAndOrderFront(self)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }
    
    func showInitialization() async -> InitializationCoordinator {
        screen = .initialization
        
        return await Task { @MainActor in
            let coordinator: InitializationCoordinator
            if let initializationCoordinator {
                coordinator = initializationCoordinator
            } else {
                let window = retrieveAlreadyPresentedWindow()
                coordinator = InitializationCoordinator(window: window)
                initializationCoordinator = coordinator
            }
            coordinator.start()
            return coordinator
        }.value
    }

    @objc func showSettings() {
        Task { @MainActor in
            if settings == nil {
                #if HAS_BUILTIN_UPDATER
                settings = SettingsCoordinator(delegate: self,
                                                     initialServices: initialServices,
                                                     launchOnBootService: launchOnBoot,
                                                     appUpdateService: appUpdateService)
                #else
                settings = SettingsCoordinator(delegate: self,
                                                     initialServices: initialServices,
                                                     launchOnBootService: launchOnBoot)
                #endif
            }
            settings!.start()
        }
    }
    
    #if HAS_QA_FEATURES
    @objc func showQASettings() {
        Task {
            if qaSettings == nil {
                let dumperDependencies: DumperDependencies?
                if let tower = postLoginServices?.tower {
                    dumperDependencies = DumperDependencies(tower: tower, 
                                                            domainOperationsService: domainOperationsService)
                } else {
                    dumperDependencies = nil
                }

                #if HAS_BUILTIN_UPDATER
                qaSettings = await QASettingsCoordinator(signoutManager: self,
                                                         sessionStore: self.initialServices.sessionVault,
                                                         mainKeyProvider: self.initialServices.keymaker,
                                                         appUpdateService: self.appUpdateService as! SparkleAppUpdateService,
                                                         eventLoopManager: self.postLoginServices?.tower,
                                                         featureFlags: self.featureFlags,
                                                         dumperDependencies: dumperDependencies)
                #else
                qaSettings = await QASettingsCoordinator(signoutManager: self,
                                                         sessionStore: self.initialServices.sessionVault,
                                                         mainKeyProvider: self.initialServices.keymaker,
                                                         eventLoopManager: self.postLoginServices?.tower,
                                                         featureFlags: self.featureFlags,
                                                         dumperDependencies: dumperDependencies)
                #endif
            }
            await qaSettings!.start()
        }
    }
    #endif

    @objc func quitApp() {
        NSApp.terminate(self)
    }

    @objc func showLogsInFinder() async throws {
        let logsDirectory = try PDFileManager.getLogsDirectory()

        do {
            #if INCLUDES_DB_IN_BUGREPORT
            let dbDestination = logsDirectory.appendingPathComponent("DB", isDirectory: true)
            
            if !FileManager.default.fileExists(atPath: dbDestination.path) {
                try FileManager.default.createDirectory(at: dbDestination, withIntermediateDirectories: true, attributes: nil)
            }
            
            let appGroupContainerURL = logsDirectory.deletingLastPathComponent()
            try PDFileManager.copyDatabases(from: appGroupContainerURL, to: dbDestination)
            #endif
            if featureFlags?.isEnabled(flag: .logsCompressionDisabled) == true {
                let logContents = try await logContentLoader.loadContent()
                for (index, logContent) in logContents.enumerated() {
                    try PDFileManager.appendLogs(logContent, toFile: "log-\(index).log", in: logsDirectory)
                }
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logsDirectory.path)
            } else {
                let archiveFileURL = logsDirectory.appendingPathComponent("LogsForCustomerSupport.aar", conformingTo: .archive)
                
                try? PDFileManager.archiveContentsOfDirectory(logsDirectory, into: archiveFileURL)
                
                NSWorkspace.shared.activateFileViewerSelecting([archiveFileURL])
            }
        } catch {
            Log.error("Error loading logs: \(error.localizedDescription)", domain: .application)
        }
    }

    @objc func showErrorView() {
        Task {
            if syncErrors == nil, let baseURL = await rootVisibleUserLocation() {
                syncErrors = await ErrorCoordinator(
                    storageManager: metadataMonitor?.syncStorage,
                    communicationService: self.communicationService,
                    baseURL: baseURL
                )
            }
            await syncErrors?.start()
        }
    }

    @objc func bugReport() {
        NSWorkspace.shared.open(Constants.reportBugURL)
    }

    private func rootVisibleUserLocation() async -> URL? {
        guard let url = try? await domainOperationsService.getUserVisibleURLForRoot() else {
            return nil
        }
        return url
    }

    @objc func didTapOnMenu(from button: NSButton) {
        Task {
            if syncCoordinator == nil {
                #if HAS_BUILTIN_UPDATER
                syncCoordinator = await SyncCoordinator(
                    metadataMonitor: metadataMonitor,
                    communicationService: self.communicationService,
                    initialServices: initialServices,
                    appUpdateService: appUpdateService, 
                    syncStateService: syncStateService,
                    delegate: self,
                    baseURL: await rootVisibleUserLocation()
                )
                #else
                syncCoordinator = await SyncCoordinator(
                    metadataMonitor: metadataMonitor,
                    communicationService: self.communicationService,
                    initialServices: initialServices,
                    syncStateService: syncStateService,
                    delegate: self,
                    baseURL: await rootVisibleUserLocation()
                )
                #endif
            }
            await syncCoordinator?.toggleMenu(from: button, menuBarState: syncStateService.menuBarState)
        }
    }

    @MainActor
    func pauseSyncing() {
        menuBarCoordinator?.pauseSyncing()
    }

    @MainActor
    func resumeSyncing() {
        menuBarCoordinator?.resumeSyncing()
    }

    private func configureForUITests() async {
        // Reverse the LSUIElement = 1 setting in the info.plist,
        // allowing the status item to be selected in UITests
        _ = await MainActor.run { NSApp.setActivationPolicy(.regular) }
        await signOutAsync()
        await showLogin()
    }

    private func dismissAnyOpenWindows() {
        login = nil
        screen = nil
        initializationCoordinator = nil
        onboardingCoordinator = nil

        DispatchQueue.main.async {
            self.window?.close()
            self.window = nil
        }

        Task {
            await settings?.stop()
            settings = nil
            
            #if HAS_QA_FEATURES
            await qaSettings?.stop()
            qaSettings = nil
            await syncErrors?.stop()
            syncErrors = nil
            #endif
            await syncCoordinator?.stop()
            syncCoordinator = nil
        }
    }

    private func makeRemoteChangeSignaler() -> RemoteChangeSignaler {
        RemoteChangeSignaler(domainOperationsService: domainOperationsService)
    }

    private func processLoginResult(_ result: LoginResult) {
        switch result {
        case .dismissed:
            self.login = nil
        case .loggedIn(let loginData):
            processLoginData(loginData)
            Log.info("AppCoordinator - loggedIn", domain: .application)
        case .signedUp:
            fatalError("Signup unimplemented")
        @unknown default:
            fatalError("Unimplemented")
        }
    }
    
    private func processLoginData(_ userData: LoginData) {
        updatePMAPIServiceSessionUID(sessionUID: userData.credential.sessionID)
        storeUserData(userData) { [weak self] maybeError in
            guard let self else { return }
            Task {
                if let error = maybeError {
                    await self.performEmergencyLogout(becauseOf: error)
                } else {
                    Log.info("AppCoordinator - storeUserData succeeded", domain: .application)
                    self.initialServices.featureFlagsRepository.setUserId(userData.user.ID)
                    do {
                        await self.fetchFeatureFlags()
                        try await self.didLogin()
                    } catch {
                        await self.performEmergencyLogout(becauseOf: error)
                    }
                }
            }
        }
    }

    private func storeUserData(_ data: UserData, completion: @escaping (Error?) -> Void) {
        let store: SessionStore = initialServices.sessionVault
        let sessionRelatedCommunicator = initialServices.sessionRelatedCommunicator
        let parentSessionCredentials = data.getCredential
        sessionRelatedCommunicator.fetchNewChildSession(parentSessionCredential: parentSessionCredentials) { result in
            switch result {
            case .success:
                store.storeCredential(CoreCredential(parentSessionCredentials))
                store.storeUser(data.user)
                store.storeAddresses(data.addresses)
                store.storePassphrases(data.passphrases)
                sessionRelatedCommunicator.onChildSessionReady()
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }
    
    private func performEmergencyLogout(becauseOf error: any Error) async {
        Log.error("AppCoordinator - login process did fail with \(error)", domain: .application)
        // in case of error, the file provider won't work at all
        // therefore we retry the login
        await signOutAsync()
        await showLogin()
    }
}

extension AppCoordinator {
    // Required if we ever add multi-session support or switch from PMAPIClient to AuthHelper as our AuthDelegate
    private func updatePMAPIServiceSessionUID(sessionUID: String) {
        initialServices.networkService.setSessionUID(uid: sessionUID)
    }

    private func errorHandler(_ error: any Error) async {
        await signOutAsync()
        let loginError = LoginError.generic(message: error.localizedDescription,
                                            code: error.bestShotAtReasonableErrorCode, 
                                            originalError: error)
        await showLogin(initialError: loginError)
    }
    
    func didLogin() async throws {
        let postLoginServices: PostLoginServices
        do {
            try await self.domainOperationsService.identifyDomain()
            postLoginServices = preparePostLoginServices()
            
            try await postLoginServices.tower.cleanUpLockedVolumeIfNeeded(using: domainOperationsService)
            
            // error fetching feature flags should not cause the login process to fail, we will use the default values
            try? await FeatureFlagsRepository.shared.fetchFlags()
            try? await postLoginServices.tower.featureFlags.startAsync()
            
            try? await domainOperationsService.tearDownDomain()
            await postLoginServices.tower.cleanUpEventsAndMetadata(cleanupStrategy: domainOperationsService.cacheCleanupStrategy)
        } catch {
            await errorHandler(error)
            throw error
        }
        
        if domainOperationsService.hasDomainReconnectionCapability {
            do {
                try await startDomainReconnection(tower: postLoginServices.tower)
            } catch {
                await errorHandler(error)
                throw error
            }
            do {
                try await startPostLoginServices(postLoginServices: postLoginServices)
            } catch {
                // we ignore the error because it's handled internally in startPostLoginServices
                return
            }
            do {
                try await finishDomainReconnection(tower: postLoginServices.tower)
            } catch {
                await errorHandler(error)
                throw error
            }
        } else {
            do {
                try await postLoginServices.tower.bootstrapIfNeeded()
            } catch {
                await errorHandler(error)
                throw error
            }
            do {
                try await startPostLoginServices(postLoginServices: postLoginServices)
            } catch {
                // we ignore the error because it's handled internally in startPostLoginServices
                return
            }
        }
        
        menuBarCoordinator?.featureFlags = self.featureFlags
    }

    private func preparePostLoginServices() -> PostLoginServices {
        let remoteChangeSignaler = makeRemoteChangeSignaler()
        let postLoginServices = self.postLoginServicesBuilder.build(with: [remoteChangeSignaler], activityObserver: { [weak self] in self?.currentActivityChanged($0)
        })
        self.postLoginServices = postLoginServices
        configureDocumentController(with: postLoginServices.tower)
        return postLoginServices
    }

    private func configureDocumentController(with tower: Tower?) {
        guard let documentController = ProtonDocumentController.shared as? ProtonDocumentController else {
            assertionFailure("ProtonDocumentController needs to be the registered DocumentController in order to handle Proton documents")
            Log.error("ProtonDocumentController needs to be the registered DocumentController in order to handle Proton documents", domain: .protonDocs)
            return
        }

        documentController.tower = tower
    }

    private func startPostLoginServices(postLoginServices: PostLoginServices) async throws {
        self.launchOnBoot.userSignedIn()

        postLoginServices.onLaunchAfterSignIn()
        do {
            let migrated: Bool

            do {
                migrated = try await performPostMigrationStep(postLoginServices)
            } catch {
                Log.error("PostMigrationStep failed: \(error.localizedDescription)", domain: .application)
                throw DomainOperationErrors.postMigrationStepFailed(error)
            }

            if !migrated {
                try await domainOperationsService.setUpDomain()
            }

            login = nil
            if screen == .login || screen == .initialization {
                showOnboarding()
            }

            metadataMonitor = metadataMonitorBuilder.build(with: postLoginServices.tower)
            if let syncStorage = metadataMonitor?.syncStorage {
                let suite: SettingsStorageSuite = .group(named: PDCore.Constants.appGroup)
                let historyObserver = PersistentHistoryObserver(
                    target: .main, suite: suite, syncStorage: syncStorage
                )
                self.communicationService = CoreDataCommunicationService<SyncItem>(
                    suite: suite,
                    entityType: SyncItem.self,
                    historyObserver: historyObserver,
                    context: syncStorage.mainContext,
                    includeHistory: true
                )
            }
            activityService = ActivityService(repository: postLoginServices.tower.client, frequency: Constants.activeFrequency)

            menuBarCoordinator?.startSyncMonitoring(eventsProcessor: postLoginServices.tower,
                                                    syncErrorsSubject: metadataMonitor?.syncErrorDBUpdatePublisher)
            menuBarCoordinator?.errorsCount = menuSyncErrorsCount

            menuBarCoordinator?.updateMenu()
        } catch {
            // if we log the user out, we don't need to care about the status of the post migration step anymore
            hasPostMigrationStepRun = nil
            // if the user logs out, we are no longer disconnected
            domainOperationsService.cacheReset = false
            // if the user logs out, we no longer need to tell them we're syncing
            menuBarCoordinator?.cacheRefreshSyncState = .synced
            let errorMessage: String = error.localizedDescription
            Log.error("PostLoginServicesErrors: \(errorMessage)", domain: .fileProvider)
            await signOutAsync()
            let loginError = error.asLoginError(with: errorMessage)
            await showLogin(initialError: loginError)
            throw error
        }
    }
    
    private func startDomainReconnection(tower: Tower) async throws {
        menuBarCoordinator?.cacheRefreshSyncState = .syncing
        if try await domainOperationsService.domainExists() {
            try await tower.bootstrapIfNeeded()
            try await refreshUsingDirtyNodesApproach(tower: tower)
        } else {
            // we clean up before bootstrap to ensure we don't keep the data from previously logged in user when boostraping a new one
            await tower.cleanUpEventsAndMetadata(cleanupStrategy: .cleanEverything)
            try await tower.bootstrapIfNeeded()
        }
        menuBarCoordinator?.cacheRefreshSyncState = .synced
    }

    private func finishDomainReconnection(tower: Tower) async throws {
        domainOperationsService.cacheReset = false
        shouldReenumerateItems = true
        try await domainOperationsService.signalEnumerator()
        tower.runEventsSystem()
    }

    private func currentActivityChanged(_ activity: NSUserActivity) {
        // TODO: migrate to PMAPIClient.failureAlertPublisher()
        guard let driveAlert = PMAPIClient.mapToFailingAlert(activity) else {
            return
        }

        Log.info("AppCoordinator - currentActivityChanged to: \(driveAlert)", domain: .application)

        switch driveAlert {
        case .logout:
            // the logout activity can happen multiple times in a row
            guard isLoggingOut.value == false else { return }
            isLoggingOut.mutate { $0 = true }
            Task { [weak self] in
                guard let self else { return }
                await self.signOutAsync()
                await self.showLogin()
                self.isLoggingOut.mutate { $0 = false }
            }
            
        case .forceUpgrade, .trustKitFailure, .trustKitHardFailure, .humanVerification, .userGoneDelinquent:
            let alert = NSAlert()
            alert.messageText = driveAlert.title
            alert.informativeText = driveAlert.message
            alert.addButton(withTitle: "Quit application")
            let action = { [weak self] in self?.quitApp() }
            
            if alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn {
                action()
            }

        default:
            break
        }
    }

    private func completeOnboarding() {
        openDriveFolder()
        initializationCoordinator = nil
        onboardingCoordinator = nil
    }

    private func didLogout() {
        configureDocumentController(with: nil)
        postLoginServices = nil
        metadataMonitor = nil
        activityService = nil

        launchOnBoot.userSignedOut()
        dismissAnyOpenWindows()
        menuBarCoordinator?.stopMonitoring()
    }
    
    private func performPostMigrationStep(_ postLoginServices: PostLoginServices) async throws -> Bool {
        Log.info("Begin post-migration step", domain: .application)
        let migrationDetector = MigrationDetector()
        let migrationPerformer = MigrationPerformer()
        
        guard migrationDetector.requiresPostMigrationStep else {
            hasPostMigrationStepRun = nil
            Log.info("No post-migration cleanup is required", domain: .application)
            return false
        }
        
        guard postLoginServices.tower.featureFlags.isEnabled(flag: .postMigrationJunkFilesCleanup) else {
            if hasPostMigrationStepRun == false {
                hasPostMigrationStepRun = nil
                let message = "Feature flag disabled while post-migration has not finished"
                Log.error(message, domain: .application)
                let error = NSError(domain: "me.proton.drive", code: 0, localizedDescription: message)
                throw DomainOperationErrors.postMigrationStepFailed(error)
            }
            Log.info("No feature flag enabled for post-migration cleanup", domain: .application)
            return false
        }

        guard initialServices.networkClient.isReachable() else {
            if hasPostMigrationStepRun == false {
                hasPostMigrationStepRun = nil
                let message = "Network connection not available while post-migration has not finished"
                Log.error(message, domain: .application)
                let error = NSError(domain: "me.proton.drive", code: 0, localizedDescription: message)
                throw DomainOperationErrors.postMigrationStepFailed(error)
            }
            Log.warning("Machine is offline, skipping post-migration cleanup till next app launch", domain: .application)
            return false
        }
        
        guard try migrationPerformer.hasFaultyNodes(in: postLoginServices.tower.storage.mainContext)
                // this guards against situation in which we removed the faulty nodes, but we haven't refreshed the DB
                || hasPostMigrationStepRun == false else {
            Log.info("No junk found in local DB, skipping post-migration cleanup", domain: .application)
            migrationDetector.postMigrationCleanupIsComplete()
            return false
        }
        
        Log.info("Faulty nodes detected, will perfom post-migration cleanup", domain: .application, sendToSentryIfPossible: true)
        
        hasPostMigrationStepRun = false

        // Drop system FileProvider cache
        postLoginServices.tower.pauseEventsSystem()
        try await domainOperationsService.disconnectDomainsTemporarily(
            reason: "Attempting to reconnect. This may take a few minutes. Please do not quit the application"
        )
        
        menuBarCoordinator?.cacheRefreshSyncState = .syncing
        
        try await migrationPerformer.performCleanup(in: postLoginServices.tower)
        try await refreshUsingEagerSyncApproach(tower: postLoginServices.tower)
        
        menuBarCoordinator?.cacheRefreshSyncState = .synced

        try await domainOperationsService.connectDomain()
        domainOperationsService.cacheReset = false
        
        // this causes the file provider to enumerate items
        shouldReenumerateItems = true
        try await domainOperationsService.signalEnumerator()
        
        hasPostMigrationStepRun = true
        
        postLoginServices.tower.runEventsSystem()

        // Mark that post-login is complete
        migrationDetector.postMigrationCleanupIsComplete()
        
        Log.info("Finished post-migration cleanup successfully", domain: .application, sendToSentryIfPossible: true)
        return true
    }
}

extension AppCoordinator: MenuBarDelegate, AppContentDelegate, SettingsCoordinatorDelegate {
    
    func showLogin() {
        Task { @MainActor in
            await showLogin()
        }
    }
    
    func refreshUserInfo() async throws {
        try await postLoginServices?.tower.refreshUserInfoAndAddresses()
    }
 
    func userRequestedSignOut() async {
        await signOutAsync()
        await showLogin()
    }

    func reportIssue() {
        bugReport()
    }

    @objc func openDriveFolder() {
        Task {
            await openDriveFolder()
        }
    }
    
    func openDriveFolder() async {
        let url: URL
        do {
            url = try await domainOperationsService.getUserVisibleURLForRoot()
        } catch {
            Log.error("Open Drive folder: Could not get user visible URL for domain: (\(error.localizedDescription))", domain: .fileManager)
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            let message = "Open Drive folder: Could not open domain (failed to access URL resource)"
            assertionFailure(message)
            Log.error(message, domain: .fileManager)
            return
        }
        defer {
            url.stopAccessingSecurityScopedResource()
        }

        guard NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) else {
            let message = "Open Drive folder: Could not open domain (failed to open domain in Finder)"
            assertionFailure(message)
            Log.error(message, domain: .fileManager)
            return
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuBarCoordinator?.menuWillOpen(withErrors: menuSyncErrorsCount)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuBarCoordinator?.menuDidClose()
    }

}

extension AppCoordinator: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        switch screen {
        case .login:
            login = nil
        case .initialization:
            initializationCoordinator = nil
        case .onboarding:
            completeOnboarding()
        case nil:
            break
        }
        screen = nil
        window = nil
    }
}

extension Error {
    func asLoginError(with message: String) -> LoginError {
        let errorCode = 10399
        return LoginError.generic(message: message, code: errorCode, originalError: self)
    }
}

#if HAS_QA_FEATURES
extension AppCoordinator: SignoutManager {}
#endif
