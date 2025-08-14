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
import ProtonCoreCryptoPatchedGoImplementation

/// Coordinates all the app's dependencies and responsibilities.
///
/// AppCoordinator
///   ↳ `ApplicationState` - data object containing all data defining the Status Window UI of the app (and none of the logic). Its properties are observed by the views.
///         This object is shared by `ApplicationEventObserver`, its dependencies, `MenuBarCoordinator`, and all WindowCoordinators. All observers write to it, and all the views observe changes to it.
///   ↳ `ApplicationEventObserver` - observes all changes relevant to the state of the status window (sync in progress? user logged in?, network reachable?, update available?), and propagates them to the menu bar status item and status window.
///     ↳ `ApplicationState` - shared with `AppCoordinator`.
///     ↳ `NetworkStateInteractor` - provides updates on whether the network is reachable.
///     ↳ `AppUpdateServiceProtocol` - provides updates on whether an app update is available.
///     ↳ `SessionVault` - provides updates on when a user logs in.
///     ↳ `LoggedInStateReporter` - provides updates on when a user logs in.
///     ↳ `GlobalProgressObserver` - provides updates on the state of uploading or downloading operations from the File Provider extension.
///       ↳ `DomainOperationsService` Events from the FileProvider.
///     ↳ `SyncDBObserver` - provides updates on files being synced.
///       ↳ `SyncDBFetchedResultObserver` - observes changes to the SyncItem DB using a `NSFetchedResultsController`.
///       ↳ `SyncStateDelegate` -  updates the `isPaused` and `isOffline` status of `EventsSystemManager` and `DomainOperationsService`.
///         ↳ `PDCore.EventsSystemManager` - CoreData (Tower).
///         ↳ `DomainOperationsService` Events from the FileProvider.
///   ↳ `MenuBarCoordinator` - logic related to then menu icon and dropdown menu.
class AppCoordinator: NSObject, ObservableObject {

    @SettingsStorage(UserDefaults.FileProvider.pathsMarkedAsKeepDownloadedKey.rawValue) var pathsMarkedAsKeepDownloaded: String?
    @SettingsStorage(UserDefaults.FileProvider.pathsMarkedAsOnlineOnlyKey.rawValue) var pathsMarkedAsOnlineOnly: String?
    @SettingsStorage(UserDefaults.FileProvider.openItemsInBrowserKey.rawValue) var openItemsInBrowser: String?
    @SettingsStorage(UserDefaults.FileProvider.shouldReenumerateItemsKey.rawValue) var shouldReenumerateItems: Bool?
    @SettingsStorage(UserDefaults.Migration.hasPostMigrationStepRunKey.rawValue) var hasPostMigrationStepRun: Bool?

    enum SignInStep {
        case login
        case initialization
        case onboarding
    }

    private let initialServices: InitialServices
    private let networkStateService: NetworkStateInteractor
    private let driveCoreAlertListener: DriveCoreAlertListener
    private let loginBuilder: LoginManagerBuilder
    private var loginManager: LoginManager?

    private var mainWindowCoordinator: MainWindowCoordinator?
    private var settingsWindowCoordinator: SettingsWindowCoordinator?
    private var syncErrorWindowCoordinator: SyncErrorWindowCoordinator?
    private var fullResyncCoordinator: FullResyncCoordinator?
#if HAS_QA_FEATURES
    private var qaSettingsWindowCoordinator: QASettingsWindowCoordinator?
#endif
    private let postLoginServicesBuilder: PostLoginServicesBuilder
    private var postLoginServices: PostLoginServices?

    var tower: Tower? { postLoginServices?.tower }

    private let logContentLoader: LogContentLoader
    private var metadataMonitor: MetadataMonitor?
    private var activityService: ActivityService?
    private let launchOnBoot: any LaunchOnBootServiceProtocol
    let domainOperationsService: DomainOperationsService

    private var testRunner: TestRunner?

    private let appUpdateService: AppUpdateServiceProtocol?
    private let subscriptionService: SubscriptionService

    private(set) var window: NSWindow?

    private let appState: ApplicationState

    private var signInStep: SignInStep?

    private var menuBarCoordinator: MenuBarCoordinator?
    private var applicationEventObserver: ApplicationEventObserver?
    private var globalProgressObserver: GlobalProgressObserver?

    private var initializationCoordinator: InitializationCoordinator?
    private var onboardingCoordinator: OnboardingCoordinator?
    private let ddkSessionCommunicator: SessionRelatedCommunicatorBetweenMainAppAndExtensions

    private let observationCenter: PDCore.UserDefaultsObservationCenter
    
    var client: PDClient.Client? {
        postLoginServices?.tower.client
    }

    var featureFlags: PDCore.FeatureFlagsRepository? {
        postLoginServices?.tower.featureFlags
    }

    private var isLoggingOut: Atomic<Bool> = .init(false)

    deinit {
        Log.trace()
        observationCenter.removeObserver(self)
    }

    @MainActor
    convenience init(_: Void) async {
        Log.trace()

        let keymaker = DriveKeymaker(autolocker: nil, keychain: DriveKeychain.shared,
                                     logging: { Log.info($0, domain: .storage) })
        let initialServices = InitialServices(
            userDefault: Constants.appGroup.userDefaults,
            clientConfig: Constants.userApiConfig,
            mainKeyProvider: keymaker,
            sessionRelatedCommunicatorFactory: { sessionStore, authenticator, _ in
                SessionRelatedCommunicatorForMainApp(
                    userDefaultsConfiguration: .forFileProviderExtension(userDefaults: Constants.appGroup.userDefaults),
                    sessionStorage: sessionStore,
                    childSessionKind: .fileProviderExtension,
                    authenticator: authenticator
                )
            }
        )
        let ddkSessionCommunicator = SessionRelatedCommunicatorForMainApp(
            userDefaultsConfiguration: .forDDK(userDefaults: Constants.appGroup.userDefaults),
            sessionStorage: initialServices.sessionVault,
            childSessionKind: .ddk,
            authenticator: initialServices.authenticator
        )
        let networkStateService = ConnectedNetworkStateInteractor(resource: MonitoringNetworkStateResource())
        networkStateService.execute()
        let driveCoreAlertListener = DriveCoreAlertListener(client: initialServices.networkClient)
        let loginBuilder = ConcreteLoginManagerBuilder(
            environment: Constants.userApiConfig.environment,
            apiServiceDelegate: initialServices.networkClient,
            forceUpgradeDelegate: initialServices.networkClient)

        let postLoginServicesBuilder = ConcretePostLoginServicesBuilder(initialServices: initialServices, eventProcessingMode: .pollAndRecord, eventLoopInterval: RuntimeConfiguration.shared.eventLoopInterval)
        let logContentLoader = FileLogContent()
        let launchOnBoot = LaunchOnBootLegacyAPIService()
        var featureFlagsAccessor: () -> PDCore.FeatureFlagsRepository? = { nil }
        let domainOperationsService = DomainOperationsService(
            accountInfoProvider: initialServices.sessionVault,
            featureFlags: { featureFlagsAccessor() },
            fileProviderManagerFactory: SystemFileProviderManagerFactory())

#if HAS_BUILTIN_UPDATER
        let appUpdateService = SparkleAppUpdateService()
#else
        let appUpdateService: AppUpdateServiceProtocol? = nil
#endif

        self.init(initialServices: initialServices,
                  networkStateService: networkStateService,
                  driveCoreAlertListener: driveCoreAlertListener,
                  loginBuilder: loginBuilder,
                  postLoginServicesBuilder: postLoginServicesBuilder,
                  logContentLoader: logContentLoader,
                  launchOnBoot: launchOnBoot,
                  appUpdateService: appUpdateService,
                  domainOperationsService: domainOperationsService,
                  ddkSessionCommunicator: ddkSessionCommunicator)

        featureFlagsAccessor = { [weak self] in self?.featureFlags }
        await ddkSessionCommunicator.performInitialSetup()
        ddkSessionCommunicator.startObservingSessionChanges()

        if RuntimeConfiguration.shared.enableTestAutomation {
            testRunner = TestRunner(coordinator: self)
        }
    }

#if DEBUG && !canImport(XCTest)
    static var counter = 0
#endif

    required init(initialServices: InitialServices,
                  networkStateService: NetworkStateInteractor,
                  driveCoreAlertListener: DriveCoreAlertListener,
                  loginBuilder: LoginManagerBuilder,
                  postLoginServicesBuilder: PostLoginServicesBuilder,
                  logContentLoader: LogContentLoader,
                  launchOnBoot: any LaunchOnBootServiceProtocol,
                  appUpdateService: AppUpdateServiceProtocol?,
                  domainOperationsService: DomainOperationsService,
                  ddkSessionCommunicator: SessionRelatedCommunicatorBetweenMainAppAndExtensions) {

#if DEBUG && !canImport(XCTest)
        // Make sure this is only instantiated once
        Self.counter += 1
        assert(Self.counter == 1)
#endif

        self.initialServices = initialServices
        self.networkStateService = networkStateService
        self.driveCoreAlertListener = driveCoreAlertListener
        self.loginBuilder = loginBuilder
        self.postLoginServicesBuilder = postLoginServicesBuilder
        self.logContentLoader = logContentLoader
        self.launchOnBoot = launchOnBoot
        self.appUpdateService = appUpdateService
        self.domainOperationsService = domainOperationsService
        self.ddkSessionCommunicator = ddkSessionCommunicator
        self.appState = ApplicationState()
        self.subscriptionService = SubscriptionService(apiService: initialServices.authenticator.apiService)

        self.observationCenter = UserDefaultsObservationCenter(userDefaults: Constants.appGroup.userDefaults)

        super.init()

        sharedInitSetup()
    }

    private func sharedInitSetup() {
        _shouldReenumerateItems.configure(with: Constants.appGroup)
        _hasPostMigrationStepRun.configure(with: Constants.appGroup)
        _pathsMarkedAsKeepDownloaded.configure(with: Constants.appGroup)
        _pathsMarkedAsOnlineOnly.configure(with: Constants.appGroup)
        _openItemsInBrowser.configure(with: Constants.appGroup)
        
        setUpObservingOpenInBrowserAction() 
        
#if HAS_QA_FEATURES
        NotificationCenter.default.addObserver(forName: .fileProviderDomainStateDidChange, object: nil, queue: nil) { [weak self] notification in
            guard let domainDisconnected = notification.userInfo?["domainDisconnected"] as? Bool else { return }
            Task { [weak self] in
                try await self?.changeCurrentDomainState(domainDisconnected: domainDisconnected)
            }
        }
#endif
    }

    private func setUpObservingOpenInBrowserAction() {
        self.observationCenter.addObserver(self, of: \.openItemsInBrowser) { [weak self] value in
            guard value??.isEmpty == false, let folders = value??.components(separatedBy: ",") else {
                return
            }

            Task {
                guard let root = try? await self?.postLoginServices?.tower.rootFolder() else { return }
                
                // Don't open more than 5 items at a time
                folders.prefix(5).forEach {
                    let folder = "\(root.identifier.shareID)/folder/\($0)"
                    UserActions(delegate: self).links.openOnlineDriveFolder(email: self?.appState.accountInfo?.email, folder: folder)
                }
                // Reset after using, so that next time the same folder is selected, it registers as an update.
                self?.openItemsInBrowser = ""
            }
        }
    }

    // MARK: - Startup

    @MainActor
    func start() async throws {
        Log.trace()

        await setUpApplicationEventObserver()

        if self.initialServices.isLoggedIn {
            try await startLoggedIn()
        } else {
            try await startLoggedOut()
        }
    }

    @MainActor
    func startLoggedIn() async throws {
        Log.trace()

        menuBarCoordinator?.showActivityIndicator()
        appState.setLaunchCompletion(5)

        try await domainOperationsService.identifyCurrentDomain()
        appState.setLaunchCompletion(20)

        await fetchFeatureFlags()
        appState.setLaunchCompletion(30)

        // must happen after the domain identification and feature flag fetching
        await GroupContainerMigrator.instance.migrateDatabasesForLoggedInUser(domainOperationsService: domainOperationsService,
                                                                              featureFlags: initialServices.featureFlagsRepository,
                                                                              logoutClosure: { [unowned self] in self.initialServices.sessionVault.signOut() })
        appState.setLaunchCompletion(35)

        let postLoginServices = preparePostLoginServices()
        appState.setLaunchCompletion(40)

        try await postLoginServices.tower.cleanUpLockedVolumeIfNeeded(using: domainOperationsService)
        appState.setLaunchCompletion(45)

        // error fetching feature flags should not cause the login process to fail, we will use the default values
        try? await postLoginServices.tower.featureFlags.startAsync()

        if try await !domainOperationsService.currentDomainExists() {
            await postLoginServices.tower.cleanUpEventsAndMetadata(cleanupStrategy: .cleanEverything)
        }
        appState.setLaunchCompletion(50)

        try await postLoginServices.tower.bootstrapIfNeeded()
        appState.setLaunchCompletion(55)

        var wasRefreshingNodes = false
        if domainOperationsService.hasDomainReconnectionCapability {
            // we're after boostrap, so TBH if there's no root, I'd question my sanity (or suspect some other thread deleting it from under me)
            guard let root = try? await postLoginServices.tower.rootFolder() else { throw Errors.rootNotFound }
            // if there are dirty nodes in DB, it means the previous run hasn't finished successfully
            let hasDirtyNodes = try await postLoginServices.tower.refresher.hasDirtyNodes(root: root)
            if hasDirtyNodes {
                await postLoginServices.tower.refresher.sendRefreshNotFinishedSentryEvent(root: root)
                try await refreshUsingDirtyNodesApproach(tower: postLoginServices.tower, root: root)
                wasRefreshingNodes = true
            }
        }
        appState.setLaunchCompletion(60)

        do {
            try await startPostLoginServices(postLoginServices: postLoginServices)
        } catch {
            // we ignore the error because it's handled internally in startPostLoginServices
            Log.info(error.localizedDescription, domain: .application)
            return
        }
        appState.setLaunchCompletion(70)

        subscriptionService.fetchSubscription(state: appState)

        if GroupContainerMigrator.instance.hasGroupContainerMigrationHappened {
            await GroupContainerMigrator.instance.presentDatabaseMigrationPopup()
        }
        appState.setLaunchCompletion(80)

        if wasRefreshingNodes {
            shouldReenumerateItems = true
            try await domainOperationsService.signalEnumerator()
        }

        appState.setLaunchCompletion(90)

        if Constants.isInUITests {
            await configureForUITests()
        } else if !initialServices.isLoggedIn {
            await errorHandler(LoginError.initialError(message: DriveCoreAlert.logout.message))
        }

        appState.setLaunchCompletion(100)
        menuBarCoordinator?.hideActivityIndicator()

        if postLoginServices.metadataDBWasRecreated {
            performFullResync()
        } else {
            performFullResync(onlyIfPreviouslyInterrupted: true)
        }
    }

    func startLoggedOut() async throws {
        Log.trace()

        await GroupContainerMigrator.instance.migrateDatabasesBeforeLogin(featureFlags: initialServices.featureFlagsRepository)

        if GroupContainerMigrator.instance.hasGroupContainerMigrationHappened {
            await GroupContainerMigrator.instance.presentDatabaseMigrationPopup()
        }

        if Constants.isInUITests {
            await configureForUITests()
        }

        await showLoginWindow()

        configureDocumentController(with: nil)

        appState.setLaunchCompletion(100)
    }

    private func fetchFeatureFlags() async {
        do {
            Log.trace()
            try await initialServices.featureFlagsRepository.fetchFlags()
            Log.trace("Fetched")
        } catch {
            // error fetching feature flags should not cause failure, we will use the default values
            Log.error("Could not retrieve feature flags", error: error, domain: .featureFlags)
        }
    }

    // MARK: - Authentication

    private func processLoginResult(_ result: LoginResult) async {
        switch result {
        case .dismissed:
            self.loginManager = nil
        case .loggedIn(let loginData):
            await processLoginData(loginData)
            Log.info("AppCoordinator - loggedIn", domain: .application)
        case .signedUp:
            fatalError("Signup unimplemented")
        }
    }

    private func processLoginData(_ userData: LoginData) async {
        await menuBarCoordinator?.showActivityIndicator()
        
        updatePMAPIServiceSessionUID(sessionUID: userData.credential.sessionID)
        do {
            try await storeUserData(userData)
        } catch {
            await menuBarCoordinator?.hideActivityIndicator()
            Log.error("AppCoordinator - store userData failed", error: error, domain: .application)
            await self.performEmergencyLogout(becauseOf: error)
            return
        }

        Log.info("AppCoordinator - storeUserData succeeded", domain: .application)
        self.initialServices.featureFlagsRepository.setUserId(userData.user.ID)
        await self.fetchFeatureFlags()

        do {
            try await self.didLogin()
        } catch {
            await menuBarCoordinator?.hideActivityIndicator()
            Log.error("AppCoordinator - didLogin failed", error: error, domain: .application)
        }
    }

    // Required if we ever add multi-session support or switch from PMAPIClient to AuthHelper as our AuthDelegate
    private func updatePMAPIServiceSessionUID(sessionUID: String) {
        initialServices.networkService.setSessionUID(uid: sessionUID)
    }

    private func storeUserData(_ data: UserData) async throws {
        let store: SessionStore = initialServices.sessionVault
        let sessionRelatedCommunicator = initialServices.sessionRelatedCommunicator
        let parentSessionCredentials = data.getCredential
        let ddkSessionCommunicator = ddkSessionCommunicator

        try await sessionRelatedCommunicator.fetchNewChildSession(parentSessionCredential: parentSessionCredentials)
        try await ddkSessionCommunicator.fetchNewChildSession(parentSessionCredential: parentSessionCredentials)
        
        store.storeCredential(CoreCredential(parentSessionCredentials))
        store.storeUser(data.user)
        store.storeAddresses(data.addresses)
        store.storePassphrases(data.passphrases)
        
        await sessionRelatedCommunicator.onChildSessionReady()
        await ddkSessionCommunicator.onChildSessionReady()
    }

    private func performEmergencyLogout(becauseOf error: any Error) async {
        // in case of error, the file provider won't work at all
        // therefore we retry the login
        await signOutAsync()
        await showLoginWindow()
    }

    func didLogin() async throws {
        await menuBarCoordinator?.showActivityIndicator()

        let postLoginServices: PostLoginServices
        do {
            try await self.domainOperationsService.identifyCurrentDomain()
            postLoginServices = preparePostLoginServices()

            try await postLoginServices.tower.cleanUpLockedVolumeIfNeeded(using: domainOperationsService)

            // error fetching feature flags should not cause the login process to fail, we will use the default values
            try? await FeatureFlagsRepository.shared.fetchFlags()
            try? await postLoginServices.tower.featureFlags.startAsync()

            try? await domainOperationsService.tearDownConnectionToAllDomains()
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

        subscriptionService.fetchSubscription(state: appState)

        await menuBarCoordinator?.hideActivityIndicator()
    }

    private func completeOnboarding() {
        openDriveFolder()
        initializationCoordinator = nil
        onboardingCoordinator = nil
    }

    private func errorHandler(_ error: any Error) async {
        await signOutAsync()
        var errorToShow = error
        if let domainError = error as? DomainOperationErrors {
            errorToShow = domainError.underlyingError
        }
        let loginError = LoginError.generic(message: errorToShow.localizedDescription,
                                            code: errorToShow.bestShotAtReasonableErrorCode,
                                            originalError: errorToShow)
        await showLoginWindow(initialError: loginError)
    }

    // MARK: - Post-login

    private func preparePostLoginServices() -> PostLoginServices {
        Log.trace()
        let remoteChangeSignaler = makeRemoteChangeSignaler()
        Log.trace("postLoginServicesBuilder.build")
        let postLoginServices = self.postLoginServicesBuilder.build(with: [remoteChangeSignaler], activityObserver: { [weak self] in self?.currentActivityChanged($0)
        })
        self.postLoginServices = postLoginServices
        Log.trace("configureDocumentController")
        configureDocumentController(with: postLoginServices.tower)
        if let applicationEventObserver {
            self.fullResyncCoordinator = FullResyncCoordinator(
                applicationEventObserver: applicationEventObserver,
                domainOperationsService: domainOperationsService,
                menuBarCoordinator: menuBarCoordinator,
                tower: postLoginServices.tower
            )
        }
        return postLoginServices
    }

    private func configureDocumentController(with tower: Tower?) {
        guard let documentController = ProtonFileController.shared as? ProtonFileController else {
            Log.error("ProtonFileController needs to be the registered DocumentController in order to handle Proton documents", domain: .protonDocs)
            assertionFailure("ProtonFileController needs to be the registered DocumentController in order to handle Proton documents")
            return
        }

        documentController.tower = tower
    }

    private func startPostLoginServices(postLoginServices: PostLoginServices) async throws {
        Log.trace()
        self.launchOnBoot.userSignedIn()
        self.initialServices.localSettings.userId = client?.credentialProvider.clientCredential()?.userID

        postLoginServices.onLaunchAfterSignIn()
        do {
            let migrated: Bool

            do {
                migrated = try await performPostMigrationStep(postLoginServices)
            } catch {
                Log.error("PostMigrationStep failed", error: error, domain: .application)
                throw DomainOperationErrors.postMigrationStepFailed(error)
            }

            if !migrated {
                try await domainOperationsService.setUpDomain()
            }

            loginManager = nil
            if signInStep == .login || signInStep == .initialization {
                showOnboardingWindow()
            }

            let observationCenter = PDCore.UserDefaultsObservationCenter(userDefaults: Constants.appGroup.userDefaults)

            metadataMonitor = MetadataMonitor(
                eventsProcessor: postLoginServices.tower,
                storage: postLoginServices.tower.storage,
                sessionVault: postLoginServices.tower.sessionVault,
                observationCenter: observationCenter)
            metadataMonitor?.startObserving()

            let telemetrySettingsRepository = LocalTelemetrySettingRepository(localSettings: self.initialServices.localSettings)
            activityService = ActivityService(repository: postLoginServices.tower.client, telemetryRepository: telemetrySettingsRepository, frequency: Constants.activeFrequency)

            let syncObserver = await SyncDBObserver(
                state: appState,
                syncStorageManager: postLoginServices.tower.syncStorage,
                eventsProcessor: postLoginServices.tower,
                domainOperationsService: domainOperationsService,
                testRunner: testRunner)

            globalProgressObserver = await GlobalProgressObserver(
                state: appState,
                domainOperationsService: domainOperationsService
            )
            
            await applicationEventObserver?.startSyncMonitoring(
                syncObserver: syncObserver,
                globalProgressObserver: globalProgressObserver,
                sessionVault: postLoginServices.tower.sessionVault
            )

            let hasPlan = initialServices.sessionVault.userInfo?.hasAnySubscription
            DriveIntegrityErrorMonitor.configure(with: Constants.appGroup, forUserWithPlan: hasPlan)
        } catch {
            // if we log the user out, we don't need to care about the status of the post migration step anymore
            hasPostMigrationStepRun = nil
            // if the user logs out, we are no longer disconnected
            domainOperationsService.cacheReset = false
            // if the user logs out, we no longer need to tell them we're syncing
            await menuBarCoordinator?.hideActivityIndicator()
            Log.error("PostLoginServicesErrors", error: error, domain: .fileProvider)
            await signOutAsync()
            let loginError = error.asLoginError(with: error.localizedDescription)
            await showLoginWindow(initialError: loginError)
            throw error
        }
    }

    func setUpApplicationEventObserver() async {
        Log.trace()

        appState.setAccountInfo(self.initialServices.sessionVault.getAccountInfo())

        self.applicationEventObserver = ApplicationEventObserver(state: appState,
                                                                 logoutStateService: initialServices,
                                                                 networkStateService: networkStateService,
                                                                 appUpdateService: appUpdateService)

        self.menuBarCoordinator = await MenuBarCoordinator(
            state: appState,
            userActions: UserActions(delegate: self))
    }

    private func performPostMigrationStep(_ postLoginServices: PostLoginServices) async throws -> Bool {
        Log.info("Begin post-migration step", domain: .application)
        let migrationDetector = MigrationDetector()
        let migrationPerformer = MigrationPerformer()

        if GroupContainerMigrator.instance.hasGroupContainerMigrationHappened {
            migrationDetector.groupContainerMigrationHappened()
        }

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
        try await domainOperationsService.disconnectAllDomainsDuringMainKeyCleanup()

        await menuBarCoordinator?.showActivityIndicator()

        try await migrationPerformer.performCleanup(in: postLoginServices.tower)
        try await refreshUsingEagerSyncApproach(tower: postLoginServices.tower)

        await menuBarCoordinator?.hideActivityIndicator()

        try await domainOperationsService.connectCurrentDomain()
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

    func showOnboardingWindow() {
        initializationCoordinator = nil

        signInStep = .onboarding

        Task { @MainActor in
            let window = retrieveAlreadyPresentedWindow()
            onboardingCoordinator = OnboardingCoordinator(window: window)
            onboardingCoordinator?.start()
        }
    }
    func showInitializationWindow() async -> InitializationCoordinator {
        signInStep = .initialization

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
}

// MARK: - Sign out

#if HAS_QA_FEATURES
extension AppCoordinator: SignoutManager {}
#endif

extension AppCoordinator {

    func signOutAsync() async {
        await signOutAsync(domainOperationsService: domainOperationsService)
        ddkSessionCommunicator.clearStateOnSignOut()
        didLogout()
    }

    func signOutAsync(domainOperationsService: DomainOperationsServiceProtocol) async {
        if let tower = postLoginServices?.tower {
            // disconnect FileProvider extensions
            try? await domainOperationsService.tearDownConnectionToAllDomains()
            await tower.destroyCache(strategy: domainOperationsService.cacheCleanupStrategy)
            tower.featureFlags.stop()
        }
        if let userId = initialServices.sessionVault.userInfo?.ID {
            initialServices.featureFlagsRepository.resetFlags(for: userId)
            initialServices.featureFlagsRepository.clearUserId()
        }
        await Tower.removeSessionInBE(
            sessionVault: initialServices.sessionVault,
            authenticator: initialServices.authenticator
        ) // Before sessionVault clean to have the credential
        initialServices.sessionVault.signOut()
        initialServices.sessionRelatedCommunicator.clearStateOnSignOut()

        // remove session from networking object when signing out
        initialServices.networkService.sessionUID = ""
    }

    private func didLogout() {
        configureDocumentController(with: nil)
        postLoginServices = nil
        activityService = nil

        launchOnBoot.userSignedOut()
        dismissAnyOpenWindows()
        applicationEventObserver?.stopMonitoring(dueToSignOut: true)
    }
}

// MARK: - Window handling

extension AppCoordinator {

    /// Create and return new window.
    private func createWindow() -> NSWindow {
        let appWindow = NSWindow()
        appWindow.styleMask = [.titled, .closable, .miniaturizable]
        appWindow.titlebarAppearsTransparent = true
        appWindow.backgroundColor = ColorProvider.BackgroundNorm
        appWindow.delegate = self
        appWindow.isReleasedWhenClosed = false
        return appWindow
    }

    /// Show current `window`.
    private func presentWindow() {
        guard let window else { return }
        window.setFrame(CGRect(x: 0, y: 0, width: 420, height: 480), display: true)
        window.level = .statusBar
        window.center()
        window.makeKeyAndOrderFront(self)

        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
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

    private func dismissAnyOpenWindows() {
        loginManager = nil
        signInStep = nil
        initializationCoordinator = nil
        onboardingCoordinator = nil

        DispatchQueue.main.async {
            self.window?.close()
            self.window = nil
        }

        Task {
            await settingsWindowCoordinator?.stop()
            settingsWindowCoordinator = nil

#if HAS_QA_FEATURES
            await qaSettingsWindowCoordinator?.stop()
            qaSettingsWindowCoordinator = nil
#endif

            await syncErrorWindowCoordinator?.stop()
            syncErrorWindowCoordinator = nil

            await mainWindowCoordinator?.stop()
            mainWindowCoordinator = nil
        }
    }

    // MARK: - Domains

#if HAS_QA_FEATURES
    func changeCurrentDomainState(domainDisconnected: Bool) async throws {
        guard let tower = postLoginServices?.tower else { return }

        if domainDisconnected {
            await menuBarCoordinator?.showActivityIndicator() // TODO: When does this get hidden?
            do {
                try await refreshUsingDirtyNodesApproach(tower: tower)
            } catch {
                if case PDFileProvider.Errors.rootNotFound = error {
                    // if there's no root, we must re-bootstrap
                    try await tower.bootstrap()
                    try await refreshUsingDirtyNodesApproach(tower: tower)
                } else {
                    await menuBarCoordinator?.hideActivityIndicator() // TODO: When else does this get hidden?
                    throw error
                }
            }

            await menuBarCoordinator?.showActivityIndicator() // TODO: When does this get hidden?

            try await domainOperationsService.connectCurrentDomain()
            domainOperationsService.cacheReset = false

            shouldReenumerateItems = true
            try await domainOperationsService.signalEnumerator()
        } else {
            let migrationPerformer = MigrationPerformer()
            try await domainOperationsService.disconnectDomainsForQA(
                reason: { $0.map { "\($0.displayName) domain disconnected" } ?? "" }
            )
            await menuBarCoordinator?.showActivityIndicator()
            try await migrationPerformer.performCleanup(in: tower)
            await menuBarCoordinator?.hideActivityIndicator()
        }
    }
#endif

    private func startDomainReconnection(tower: Tower) async throws {
        await menuBarCoordinator?.showActivityIndicator()
        if try await domainOperationsService.currentDomainExists() {
            try await tower.bootstrapIfNeeded()
            try await refreshUsingDirtyNodesApproach(tower: tower)
        } else {
            // we clean up before bootstrap to ensure we don't keep the data from previously logged in user when boostraping a new one
            await tower.cleanUpEventsAndMetadata(cleanupStrategy: .cleanEverything)
            try await tower.bootstrapIfNeeded()
        }
        await menuBarCoordinator?.hideActivityIndicator()
    }

    private func finishDomainReconnection(tower: Tower) async throws {
        domainOperationsService.cacheReset = false
        shouldReenumerateItems = true
        try await domainOperationsService.signalEnumerator()
        tower.runEventsSystem()
    }

    private func refreshUsingEagerSyncApproach(tower: Tower) async throws {
        guard let rootFolder = try? await tower.rootFolder() else {
            throw Errors.rootNotFound
        }

        let coordinator = await showInitializationWindow()

        do {
            coordinator.update(progress: .init())

            try await tower.refresher.refreshUsingEagerSyncApproach(root: rootFolder, shouldIncludeDeletedItems: true)
        } catch {
            coordinator.showFailure(error: error) { [weak self] in
                try await self?.refreshUsingEagerSyncApproach(tower: tower)
            }
        }
    }

    private func refreshUsingDirtyNodesApproach(tower: Tower, root: Folder? = nil, retrying: Bool = false) async throws {
        var rootFolder: Folder? = root
        if rootFolder == nil {
            rootFolder = try await tower.rootFolder()
        }
        guard let rootFolder else {
            throw Errors.rootNotFound
        }

        let coordinator = await showInitializationWindow()
        coordinator.update(progress: .init(totalValue: 1))

        do {
            try await tower.refresher.refreshUsingDirtyNodesApproach(root: rootFolder, resumingOnRetry: retrying) { current, total in
                Task { @MainActor in
                    let progress = InitializationProgress(currentValue: current, totalValue: total)
                    self.initializationCoordinator?.update(progress: progress)
                }
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

    // MARK: - Misc

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
                await self.showLoginWindow()
                self.isLoggingOut.mutate { $0 = false }
            }

        case .forceUpgrade, .trustKitFailure, .trustKitHardFailure, .humanVerification, .userGoneDelinquent:
            let alert = NSAlert()
            alert.messageText = driveAlert.title
            alert.informativeText = driveAlert.message
            alert.addButton(withTitle: "Quit application")
            let action = { [weak self] in UserActions(delegate: self).app.quitApp() }

            if alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn {
                action()
            }
        }
    }

    private func rootVisibleUserLocation() async -> URL? {
        guard let url = try? await domainOperationsService.getUserVisibleURLForRoot() else {
            return nil
        }
        return url
    }

    private func makeRemoteChangeSignaler() -> RemoteChangeSignaler {
        RemoteChangeSignaler(domainOperationsService: domainOperationsService)
    }

    private func presentConfirmationDialog(
        messageText: String,
        informativeText: String = "",
        actionButtonText: String = "OK", action: () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText

        alert.addButton(withTitle: actionButtonText)
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            action()
        default:
            break
        }
    }

    // MARK: - Tests

    private func configureForUITests() async {
        // Reverse the LSUIElement = 1 setting in the info.plist,
        // allowing the status item to be selected in UITests
        _ = await MainActor.run { NSApp.setActivationPolicy(.regular) }
        await signOutAsync()
        await showLoginWindow()
    }
}

// MARK: - NSWindowDelegate

extension AppCoordinator: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        switch signInStep {
        case .login:
            loginManager = nil
        case .initialization:
            initializationCoordinator = nil
        case .onboarding:
            completeOnboarding()
        case nil:
            break
        }
        signInStep = nil
        window = nil
    }
}

// MARK: - UserActionsDelegate

extension AppCoordinator: UserActionsDelegate {
    func toggleStatusWindow(from backup_button: NSButton? = nil, onlyOpen: Bool) {
        Task { @MainActor in
            if mainWindowCoordinator?.isOpen == true && onlyOpen {
                Log.trace("Not continuing because already open")
                return
            }
            
            prepareMainWindowCoordinator()

            let button = menuBarCoordinator?.button ?? backup_button ?? NSButton()

            let didOpenWindow = mainWindowCoordinator?.toggleMenu(from: button)
            if didOpenWindow == true {
                try await applicationEventObserver?.refreshItems()
            }
        }
    }

    func showStatusWindow(from backup_button: NSButton?) {
        toggleStatusWindow(from: backup_button, onlyOpen: true)
    }

    @MainActor
    private func prepareMainWindowCoordinator() {
        if mainWindowCoordinator == nil {
#if HAS_QA_FEATURES
            let userActions = UserActions(delegate: self, observer: applicationEventObserver)
#else
            let userActions = UserActions(delegate: self)
#endif
            mainWindowCoordinator = MainWindowCoordinator(
                appState,
                userActions: userActions
            )
        }
    }

#if HAS_BUILTIN_UPDATER
    func installUpdate() {
        appUpdateService?.installUpdateIfAvailable()
    }

    func checkForUpdates() {
        appUpdateService?.checkForUpdates()
    }
#endif

    func userRequestedSignOut() async {
        await signOutAsync()
        await showLoginWindow()
    }

    func refreshUserInfo() {
        Task {
            do {
                try await postLoginServices?.tower.refreshUserInfoAndAddresses()
            } catch {
                Log.error("refreshUserInfoAndAddresses failed", error: error, domain: .application)
            }
        }
    }

    func pauseSyncing() {
        performWithLogging { [weak self] in
            try await self?.applicationEventObserver?.pauseSyncing()
        }
    }

    func resumeSyncing() {
        performWithLogging { [weak self] in
            try await self?.applicationEventObserver?.resumeSyncing()
        }
    }

    func togglePausedStatus() {
        performWithLogging { [weak self] in
            try await self?.applicationEventObserver?.togglePausedStatus()
        }
    }

    func cleanUpErrors() {
        applicationEventObserver?.cleanUpErrors()
        domainOperationsService.cleanUpErrors()
    }

    func signInUsingTestCredentials(login: String, password: String) {
        Task { @MainActor in
            await userRequestedSignOut()
            loginManager?.logIn(as: login, password: password)
        }
    }

    func performFullResync(onlyIfPreviouslyInterrupted: Bool = false) {
        fullResyncCoordinator?.performFullResync(onlyIfPreviouslyInterrupted: onlyIfPreviouslyInterrupted)
    }

    func finishFullResync() {
        fullResyncCoordinator?.finishFullResync()
    }

    func retryFullResync() {
        fullResyncCoordinator?.retryFullResync()
    }
    
    func cancelFullResync() {
        fullResyncCoordinator?.cancelFullResync()
    }
    
    func abortFullResync() {
        fullResyncCoordinator?.abortFullResync()
    }

    func showLogin() {
        Task { @MainActor in
            await showLoginWindow()
        }
    }

    func toggleDetailedLogging() {
        let actionVerb = RuntimeConfiguration.shared.includeTracesInLogs ? "disable" : "enable"
        self.presentConfirmationDialog(
            messageText: "Application restart required",
            informativeText: "To \(actionVerb) detailed logging, we need to restart the application.\nPending and in-progress uploads will resume automatically.",
            actionButtonText: "Restart"
        ) {
            try? RuntimeConfiguration.shared.toggleDetailedLogging()
        }
    }

    @MainActor
    private func showLoginWindow(initialError: LoginError? = nil) async {
        self.signInStep = .login
        if let loginManager = self.loginManager {
            loginManager.presentLoginFlow(
                with: initialError ?? self.driveCoreAlertListener.initialLoginError()
            )
        } else {
            let appWindow = createWindow()
            self.window = appWindow

            let loginManager = self.loginBuilder.build(in: appWindow) { [weak self] result in
                guard let self = self else { return }
                await self.processLoginResult(result)
            }

            self.loginManager = loginManager
            loginManager.presentLoginFlow(
                with: initialError ?? self.driveCoreAlertListener.initialLoginError()
            )
        }
    }

    func showErrorWindow() {
        Task {
            syncErrorWindowCoordinator = await SyncErrorWindowCoordinator(state: appState, actions: UserActions(delegate: self))
            await syncErrorWindowCoordinator?.start()
        }
    }

    func showLogsInFinder() async throws {
        let logsDirectory = PDFileManager.logsDirectory

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
            Log.error("Error loading logs", error: error, domain: .application)
        }
    }

    func showLogsWhenNotConnected() {
        // Just opening
        guard let logsDirectory = try? PDFileManager.getLogsDirectory() else {
            Log.info("No Logs directory created yet", domain: .application)
            return
        }
        let dbDestination = logsDirectory.appendingPathComponent("DB", isDirectory: true)
        let appGroupContainerURL = logsDirectory.deletingLastPathComponent()
        try? PDFileManager.copyDatabases(from: appGroupContainerURL, to: dbDestination)

        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logsDirectory.path)
    }

    func showSettings() {
        Task { @MainActor in
            if settingsWindowCoordinator == nil {
                settingsWindowCoordinator = SettingsWindowCoordinator(
                    sessionVault: initialServices.sessionVault,
                    launchOnBootService: launchOnBoot,
                    userActions: UserActions(delegate: self),
                    appUpdateService: appUpdateService,
                    isFullResyncEnabled: { [weak self] in
                        self?.postLoginServices?.tower.featureFlags.isEnabled(flag: .driveMacSyncRecoveryDisabled) != true
                    }
                )
            }
            settingsWindowCoordinator!.start()
        }
    }
    
    func closeSettingsAndShowMainWindow() {
        Task { @MainActor in
            settingsWindowCoordinator?.stop()
            menuBarCoordinator?.showMenuProgramatically()
        }
    }

#if HAS_QA_FEATURES
    func showQASettings() {
        Task {
            if qaSettingsWindowCoordinator == nil {
                let dumperDependencies: DumperDependencies?
                if let tower = postLoginServices?.tower {
                    dumperDependencies = DumperDependencies(tower: tower,
                                                            domainOperationsService: domainOperationsService)
                } else {
                    dumperDependencies = nil
                }

                qaSettingsWindowCoordinator = await QASettingsWindowCoordinator(
                    signoutManager: self,
                    sessionStore: self.initialServices.sessionVault,
                    mainKeyProvider: self.initialServices.mainKeyProvider,
                    appUpdateService: self.appUpdateService,
                    eventLoopManager: self.postLoginServices?.tower,
                    featureFlags: self.featureFlags,
                    dumperDependencies: dumperDependencies,
                    userActions: UserActions(delegate: self),
                    applicationEventObserver: applicationEventObserver!,
                    metadataStorage: self.tower?.storage,
                    eventsStorage: self.tower?.eventStorageManager,
                    jailDependencies: self.client.map { (initialServices.networkService, $0) }
                )
            }
            await qaSettingsWindowCoordinator!.start()
        }
    }

    @MainActor
    func toggleGlobalProgressStatusItem() {
        globalProgressObserver?.toggleGlobalProgressStatusItem()
    }
#endif

    func openDriveFolder(fileLocation: String? = nil) {
        Task { @MainActor in

            let driveFolderURL: URL
            do {
                driveFolderURL = try await domainOperationsService.getUserVisibleURLForRoot()
            } catch {
                Log.error("Open Drive folder: Could not get user visible URL for domain", error: error, domain: .fileManager)
                return
            }

            guard driveFolderURL.startAccessingSecurityScopedResource() else {
                let message = "Open Drive folder: Could not open domain (failed to access URL resource)"
                assertionFailure(message)
                Log.error(message, domain: .fileManager)
                return
            }
            defer {
                driveFolderURL.stopAccessingSecurityScopedResource()
            }

            var absoluteFilePath: String?
            if let fileLocation {
                absoluteFilePath = driveFolderURL.path + fileLocation
            }

            // Even though the first parameter of `selectFile` can be empty,
            // if it is and `inFileViewerRootedAtPath` is set to `driveFolderURL.path`,
            // sometimes the folder won't load properly following sign-in.
            guard NSWorkspace.shared.selectFile(absoluteFilePath ?? driveFolderURL.path, inFileViewerRootedAtPath: "") else {
                // File not found (may have been deleted) - opening Drive folder instead.
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: driveFolderURL.path)
                let message = "Open Drive folder: Could not open requested file (\(absoluteFilePath ?? "n/a"))"
                Log.info(message, domain: .fileManager)
                return
            }
        }
    }
    
    func keepDownloaded(paths: [String]) {
        Task {
            do {
                pathsMarkedAsKeepDownloaded = try await itemIdentifierStrings(for: paths).joined(separator: ":")
                try await domainOperationsService.signalEnumerator()
            } catch {
                Log.error("Error calling keepDownloaded from TestRunner", error: error, domain: .testRunner)
            }
        }
    }
    
    func keepOnlineOnly(paths: [String]) {
        Task {
            do {
                pathsMarkedAsOnlineOnly = try await itemIdentifierStrings(for: paths).joined(separator: ":")
                try await domainOperationsService.signalEnumerator()
            } catch {
                Log.error("Error calling keepOnlineOnly from TestRunner", error: error, domain: .testRunner)
            }
        }
    }
    
    private func itemIdentifierStrings(for paths: [String]) async throws -> [String] {
        var itemIdentifiers: [String] = []
        
        let rootURL = try await domainOperationsService.getUserVisibleURLForRoot()
        let absolutePaths = paths.map { rootURL.appendingPathComponent($0).absoluteString }

        for path in absolutePaths {
            let url = URL(string: path)!
            
            let (itemIdentifier, _) = try await NSFileProviderManager.identifierForUserVisibleFile(at: url)
            itemIdentifiers.append(itemIdentifier.id)
        }
        return itemIdentifiers
    }
}

// MARK: -

extension Error {
    func asLoginError(with message: String) -> LoginError {
        let errorCode = 10399
        return LoginError.generic(message: message, code: errorCode, originalError: self)
    }
}

private extension UserDefaults {
    enum Migration: String {
        case hasPostMigrationStepRunKey = "hasPostMigrationStepRun"
    }
}

func performWithLogging(domain: LogDomain = .application,
                        sendToSentryIfPossible: Bool = true,
                        file: String = #file,
                        function: String = #function,
                        line: Int = #line,
                        _ block: @escaping () async throws -> Void) {
    Task {
        do {
            try await block()
        } catch {
            Log.error("performWithLogging error",
                      error: error,
                      domain: domain,
                      sendToSentryIfPossible: sendToSentryIfPossible,
                      file: file,
                      function: function,
                      line: line
            )
        }
    }
}
