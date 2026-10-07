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
import PDLocalization
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
///     ↳ `AppUpdateServiceProtocol` - provides updaes on whether an app update is available.
///     ↳ `SessionVault` - provides updates on when a user logs in.
///     ↳ `LoggedInStateReporter` - provides updates on when a user logs in.
///     ↳ `GlobalProgressObserver` - owns domain progress observation and updates application state.
///       ↳ `GlobalProgressStreamSource` - supplies progress from the File Provider extension over XPC.
///     ↳ `SyncDBObserver` - provides updates on files being synced.
///       ↳ `SyncDBFetchedResultObserver` - observes changes to the SyncItem DB using a `NSFetchedResultsController`.
///       ↳ `SyncStateDelegate` -  updates the `isPaused` and `isOffline` status of `EventsSystemManager` and `DomainOperationsService`.
///         ↳ `PDCore.EventsSystemManager` - CoreData (Tower).
///         ↳ `DomainOperationsService` Events from the FileProvider.
///     ↳ `PromoCampaignInteractor` - provides information about active promo campaigns, used for the banner within the tray app.
///   ↳ `MenuBarCoordinator` - logic related to then menu icon and dropdown menu.
///   ↳ `DBPerformanceMetricsReporter` - logic related to watching the performance metrics DB and sending
///   signals to observability system.
class AppCoordinator: NSObject, ObservableObject {

    @SettingsStorage(UserDefaults.FileProvider.pathsMarkedAsKeepDownloadedKey.rawValue) var pathsMarkedAsKeepDownloaded: String?
    @SettingsStorage(UserDefaults.FileProvider.pathsMarkedAsOnlineOnlyKey.rawValue) var pathsMarkedAsOnlineOnly: String?
    @SettingsStorage(UserDefaults.FileProvider.openItemsInBrowserKey.rawValue) var openItemsInBrowser: String?
    @RawRepresentableSettingsStorage(UserDefaults.FileProvider.shouldReenumerateItemsKey.rawValue, defaultValue: ChangesEnumerationMode.eventLoop) var shouldReenumerateItems: ChangesEnumerationMode
    @SettingsStorage(UserDefaults.Migration.hasPostMigrationStepRunKey.rawValue) var hasPostMigrationStepRun: Bool?
    @SettingsStorage(UserDefaults.FileProvider.forceRemoveDomainOnSignOutKey.rawValue) var forceRemoveDomainOnSignOut: Bool?

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
    private var fullResyncCoordinator: FullResyncCoordinating?

    /// Guards the destructive create-fresh-domain flow against re-entry while one is already running
    /// (e.g. a second "Create new sync folder" tap before the first finishes).
    private var isCreatingFreshDomain = false

    /// Creates the full-resync coordinator; overridable in tests to inject a double.
    var makeFullResyncCoordinator: (FullResyncApplicationStateObserverProtocol, DomainOperationsServiceProtocol, MenuBarCoordinator?, @escaping () async -> Void, @escaping () -> Bool, Tower) -> FullResyncCoordinating = { observer, domainOperationsService, menuBarCoordinator, openDriveFolder, isRefreshEventResyncDisabled, tower in
        FullResyncCoordinator(applicationEventObserver: observer,
                              domainOperationsService: domainOperationsService,
                              menuBarCoordinator: menuBarCoordinator,
                              openDriveFolder: openDriveFolder,
                              isRefreshEventResyncDisabled: isRefreshEventResyncDisabled,
                              tower: tower)
    }
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
    // Changes when login, logout, or fresh-domain recovery starts. Work from an older
    // session must not install progress observation or update the replacement session.
    @MainActor private var sessionGeneration = UUID()
    @MainActor private var pendingSignOut: Task<UUID, Never>?

    private var testRunner: TestRunner?

    private let appUpdateService: AppUpdateServiceProtocol?
    private let subscriptionService: SubscriptionService
    private let performanceMetricsReporter: DBPerformanceMetricsReporter

    private(set) var window: NSWindow?

    let appState: ApplicationState
    @MainActor
    lazy var volumeLockLifecycleController: VolumeLockLifecycleController = {
        let controller = VolumeLockLifecycleController(appState: appState)
        controller.delegate = self
        return controller
    }()

    private var signInStep: SignInStep?

    private var menuBarCoordinator: MenuBarCoordinator?
    private let applicationEventObserver: ApplicationEventObserver
    private var syncStateDelegate: SyncStateDelegate?
    /// True exactly while the full post-login startup sequence has completed and services are running.
    /// Set only at the success points of continueLoggedInStartup/continueDidLogin — a mid-sequence throw
    /// leaves it false so volume-lock recovery re-runs the full startup instead of the light restore path.
    private(set) var didStartPostLoginServices = false
    private var promoCampaignInteractor: PromoCampaignInteractorProtocol

    private var initializationCoordinator: InitializationCoordinator?
    @MainActor private var migrationCancelToken: CancelToken?
    private let migrationCleanup: @MainActor (Tower) async throws -> Void
    private let migrationRefresh: @MainActor (Tower, CancelToken) async throws -> RefreshedNodesReport
    private var onboardingCoordinator: OnboardingCoordinator?

    private let observationCenter: PDCore.UserDefaultsObservationCenter

    var client: PDClient.Client? {
        postLoginServices?.tower.client
    }

    var featureFlags: DriveFeatureFlagsProvider? {
        // Before login the tower does not exist yet, but its feature flags repository is the same single
        // instance owned by InitialServices, so capability checks (e.g. the login "create fresh location"
        // toggle) reflect the flag values persisted by a previous session instead of defaulting to false.
        initialServices.featureFlags
    }

    deinit {
        Log.trace()
        observationCenter.removeObserver(self)
    }

    @MainActor
    convenience init(_: Void) async {
        Log.trace()

        let keymaker = DriveKeymaker(
            autolocker: nil,
            keychain: DriveKeychain.shared,
            logging: { Log.info($0, domain: .storage) }
        )
        let initialServices = InitialServices(
            userDefault: Constants.appGroup.userDefaults,
            clientConfig: Constants.userApiConfig,
            mainKeyProvider: keymaker,
            autoLocker: nil,
            sessionRelatedCommunicatorFactory: { sessionStore, authenticator, _ in
                SessionRelatedCommunicatorForMainApp(
                    userDefaultsConfiguration: .forFileProviderExtension(userDefaults: Constants.appGroup.userDefaults),
                    sessionStorage: sessionStore,
                    authenticator: authenticator
                )
            },
            isDetailedLoggingEnabled: { RuntimeConfiguration.shared.includeTracesInLogs }
        )
        let networkStateService = ConnectedNetworkStateInteractor(resource: initialServices.connectionStateResource)
        networkStateService.startMonitoring()
        let driveCoreAlertListener = DriveCoreAlertListener(client: initialServices.networkClient)
        let loginBuilder = ConcreteLoginManagerBuilder(
            environment: Constants.userApiConfig.environment,
            apiServiceDelegate: initialServices.networkClient,
            forceUpgradeDelegate: initialServices.networkClient)

        let postLoginServicesBuilder = ConcretePostLoginServicesBuilder(initialServices: initialServices, eventProcessingMode: .pollAndRecord, eventLoopInterval: RuntimeConfiguration.shared.eventLoopInterval, scanEngineV2TestOverride: { RuntimeConfiguration.shared.forceSyncMetadataScanV2 })
        let logContentLoader = FileLogContent()
        let launchOnBoot = LaunchOnBootLegacyAPIService()
        var featureFlagsAccessor: () -> PDCore.DriveFeatureFlagsProvider? = { nil }
        let domainOperationsService = DomainOperationsService(
            accountInfoProvider: initialServices.sessionVault,
            featureFlags: { featureFlagsAccessor() },
            fileProviderManagerFactory: SystemFileProviderManagerFactory())
        let promoCampaignInteractor = PromoCampaignInteractor.shared

#if HAS_BUILTIN_UPDATER
        let featureFlagCache = initialServices.localSettings
        let appUpdateService = SparkleAppUpdateService(
            gradualRolloutEnabled: featureFlagCache.isFeatureEnabled(.driveMacGradualRolloutChannelEnabled)
        )
#else
        let appUpdateService: AppUpdateServiceProtocol? = nil
#endif

        self.init(
            initialServices: initialServices,
            networkStateService: networkStateService,
            driveCoreAlertListener: driveCoreAlertListener,
            loginBuilder: loginBuilder,
            postLoginServicesBuilder: postLoginServicesBuilder,
            logContentLoader: logContentLoader,
            launchOnBoot: launchOnBoot,
            appUpdateService: appUpdateService,
            domainOperationsService: domainOperationsService,
            promoCampaignInteractor: promoCampaignInteractor
        )

        featureFlagsAccessor = { [weak self] in
            self?.featureFlags
        }
        await initialServices.sessionRelatedCommunicator.performInitialSetup()
        initialServices.sessionRelatedCommunicator.startObservingSessionChanges()

        if RuntimeConfiguration.shared.enableTestAutomation {
            testRunner = TestRunner(coordinator: self)
        }
    }

#if DEBUG
    static var counter = 0
#endif

    @MainActor
    required init(
        initialServices: InitialServices,
        networkStateService: NetworkStateInteractor,
        driveCoreAlertListener: DriveCoreAlertListener,
        loginBuilder: LoginManagerBuilder,
        postLoginServicesBuilder: PostLoginServicesBuilder,
        logContentLoader: LogContentLoader,
        launchOnBoot: any LaunchOnBootServiceProtocol,
        appUpdateService: AppUpdateServiceProtocol?,
        domainOperationsService: DomainOperationsService,
        promoCampaignInteractor: PromoCampaignInteractorProtocol,
        progressSource: (any GlobalProgressSource)? = nil,
        migrationCleanup: @escaping @MainActor (Tower) async throws -> Void = { try await MigrationPerformer().performCleanup(in: $0) },
        migrationRefresh: @escaping @MainActor (Tower, CancelToken) async throws -> RefreshedNodesReport = AppCoordinator.refreshMigrationMetadata
    ) {

#if DEBUG
        Self.counter += 1

        // Make sure this is only instantiated once only if we're not running tests
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            assert(Self.counter == 1)
        }
#endif

        self.migrationCleanup = migrationCleanup
        self.migrationRefresh = migrationRefresh
        self.initialServices = initialServices
        self.networkStateService = networkStateService
        self.driveCoreAlertListener = driveCoreAlertListener
        self.loginBuilder = loginBuilder
        self.postLoginServicesBuilder = postLoginServicesBuilder
        self.logContentLoader = logContentLoader
        self.launchOnBoot = launchOnBoot
        self.appUpdateService = appUpdateService
        self.domainOperationsService = domainOperationsService
        self.appState = ApplicationState()
        self.subscriptionService = SubscriptionService(apiService: initialServices.authenticator.apiService)
        self.observationCenter = UserDefaultsObservationCenter(userDefaults: Constants.appGroup.userDefaults)
        self.performanceMetricsReporter = DBPerformanceMetricsReporter()
        self.promoCampaignInteractor = promoCampaignInteractor
        self.applicationEventObserver = ApplicationEventObserver(
            state: appState,
            logoutStateService: initialServices,
            networkStateService: networkStateService,
            appUpdateService: appUpdateService,
            promoCampaignInteractor: promoCampaignInteractor,
            progressSource: progressSource ?? GlobalProgressStreamSource()
        )

        super.init()

        sharedInitSetup()
    }

    private func sharedInitSetup() {
        _shouldReenumerateItems.configure(with: Constants.appGroup)
        _hasPostMigrationStepRun.configure(with: Constants.appGroup)
        _forceRemoveDomainOnSignOut.configure(with: Constants.appGroup)
        _pathsMarkedAsKeepDownloaded.configure(with: Constants.appGroup)
        _pathsMarkedAsOnlineOnly.configure(with: Constants.appGroup)
        _openItemsInBrowser.configure(with: Constants.appGroup)

        setUpObservingOpenInBrowserAction()
        setUpObservingVolumeLockCheckRequests()
    }

    private func setUpObservingOpenInBrowserAction() {
        self.observationCenter.addObserver(self, of: \.openItemsInBrowser) { [weak self] value in
            guard value??.isEmpty == false, let folders = value??.components(separatedBy: ",") else {
                return
            }

            Task {
                guard let moc = self?.postLoginServices?.tower.storage.backgroundContext,
                      let root = try? await self?.postLoginServices?.tower.rootFolder(moc: moc)
                else { return }

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

    private func setUpObservingVolumeLockCheckRequests() {
        // The FP extension writes a timestamp at startup asking the app (the authority for the network
        // lock check) to validate the volume on its behalf. KVO fires on new writes only (no .initial),
        // so there is no stale trigger at registration; requests written while the app was dead are
        // covered by the launch-time reconcile, and reconcile no-ops while logged out (no tower).
        observationCenter.addObserver(self, of: \.volumeLockCheckRequestedAt) { [weak self] _ in
            Task { @MainActor [weak self] in
                do {
                    try await self?.volumeLockLifecycleController.reconcile(trigger: .fileProviderHint)
                } catch {
                    Log.error("File-provider-requested volume lock check failed", error: error, domain: .application)
                }
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
            await startLoggedOut()
        }
    }

    @MainActor
    func startLoggedIn() async throws {
        Log.trace()
        guard await waitForPendingSignOut() else { return }
        let generation = beginSession()
        do {
            try await startLoggedIn(generation: generation)
        } catch {
            // Superseded launch work is healthy cancellation. The winning transition owns
            // recovery and presentation; only a current launch error belongs to AppDelegate.
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            throw error
        }
    }

    @MainActor
    private func startLoggedIn(generation: UUID) async throws {
        menuBarCoordinator?.showActivityIndicator()
        appState.setLaunchCompletion(5)

        try await domainOperationsService.identifyCurrentDomain(generation: generation)
        try checkSession(generation)
        appState.setLaunchCompletion(20)

        await fetchFeatureFlags()
        try checkSession(generation)
        appState.setLaunchCompletion(30)

        // must happen after the domain identification and feature flag fetching
        await GroupContainerMigrator.instance.migrateDatabasesForLoggedInUser(domainOperationsService: domainOperationsService,
                                                                              featureFlags: initialServices.featureFlagsRepository,
                                                                              logoutClosure: { [unowned self] in self.initialServices.sessionVault.signOut() })
        try checkSession(generation)
        appState.setLaunchCompletion(35)

        let postLoginServices = preparePostLoginServices()
        appState.setLaunchCompletion(40)

        let lockOutcome: VolumeLockLifecycleController.Outcome
        do {
            lockOutcome = try await volumeLockLifecycleController.reconcile(trigger: .launch)
        } catch let error where identifyNetworkErrorDuringVolumeLockCheck(error) {
            // Can't reach the BE: we cannot deterministically know the lock state, so we never enter
            // locked mode from a failed check — continue startup with cached state (develop parity for
            // offline launches). isVolumeLocked can only be true here if an earlier *successful*
            // resolution already confirmed the lock and a later recovery step failed on network; in that
            // already-confirmed case take the locked early-return instead of booting sync against a
            // known-locked volume. Non-network errors still propagate.
            Log.warning("Launch volume-lock check failed with a network error; continuing startup with cached state", domain: .application)
            lockOutcome = appState.isVolumeLocked ? .alreadyLocked : .active
        }
        // .recovered means the controller already ran the resume startup path via the delegate.
        try checkSession(generation)
        guard lockOutcome == .active else {
            appState.setLaunchCompletion(100)
            menuBarCoordinator?.hideActivityIndicator()
            return
        }

        try await continueLoggedInStartup(postLoginServices: postLoginServices)
    }

    private func identifyNetworkErrorDuringVolumeLockCheck(_ error: Error) -> Bool {
        guard let responseError = error as? ResponseError else {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                return true
            }
            return nsError.underlyingErrors.map(identifyNetworkErrorDuringVolumeLockCheck).contains(true)
        }
        if responseError.isApiIsBlockedError || responseError.isNetworkIssueError {
            return true
        }
        if let underlyingError = responseError.underlyingError {
            return identifyNetworkErrorDuringVolumeLockCheck(underlyingError)
        }
        return false
    }

    @MainActor
    private func continueLoggedInStartup(postLoginServices: PostLoginServices) async throws {
        let generation = sessionGeneration
        guard self.postLoginServices === postLoginServices else { throw CancellationError() }
        appState.setLaunchCompletion(45)

        // error fetching feature flags should not cause the login process to fail, we will use the default values
        try? await postLoginServices.tower.featureFlags.startAsync()
        try checkSession(generation)

        let domainExists = try await domainOperationsService.currentDomainExists()
        try checkSession(generation)
        if !domainExists {
            await postLoginServices.tower.cleanUpEventsAndMetadata(cleanupStrategy: .cleanEverything)
            postLoginServices.tower.discardPersistedEventsState()
            try checkSession(generation)
        }
        appState.setLaunchCompletion(50)

        // Auto-resume an interrupted login reconnection: a previous login disconnected all domains for
        // a cache rebuild (flag set) that never reached reenumeration. Resume via the login-reconnection
        // resync, not the default setUpDomain + interrupted-only resync (which runs as .userStarted and
        // would never clear the flag). Keep the domain disconnected (skipSetUpDomain) until the rebuild
        // succeeds and the resync reconnects it.
        let isInterruptedLoginReconnection = domainOperationsService.hasDomainReconnectionCapability
            && domainOperationsService.keepDomainDisconnectedForCacheRebuild == true
            && domainExists

        try await postLoginServices.tower.bootstrapIfNeeded()
        try checkSession(generation)
        appState.setLaunchCompletion(60)

        let migrated: Bool
        do {
            migrated = try await startPostLoginServices(postLoginServices: postLoginServices, skipSetUpDomain: isInterruptedLoginReconnection)
        } catch {
            // startPostLoginServices owns recovery, including any replacement login window.
            // A superseded continuation also exits here without presenting a second error.
            return
        }
        try checkSession(generation)
        appState.setLaunchCompletion(70)

        subscriptionService.fetchSubscription(state: appState)

        if GroupContainerMigrator.instance.hasGroupContainerMigrationHappened {
            await GroupContainerMigrator.instance.presentDatabaseMigrationPopup()
            try checkSession(generation)
        }
        appState.setLaunchCompletion(80)

        didStartPostLoginServices = true
        appState.setLaunchCompletion(90)

        if Constants.isInUITests {
            await configureForUITests()
        } else if !initialServices.isLoggedIn {
            await errorHandler(LoginError.initialError(message: DriveCoreAlert.logout.message))
        }

        try checkSession(generation)

        appState.setLaunchCompletion(100)
        menuBarCoordinator?.hideActivityIndicator()

        performanceMetricsReporter.startReporting()

        // Migration has already rebuilt the metadata and signaled enumeration, including when
        // startup originally detected an interrupted reconnection or a recreated metadata DB.
        guard !migrated else { return }
        if isInterruptedLoginReconnection && domainOperationsService.keepDomainDisconnectedForCacheRebuild == true {
            startLoginReconnectionResync()
        } else if postLoginServices.metadataDBWasRecreated {
            // If we don't have the previous metadata DB, we cannot detect the deletions.
            // We therefore must rely on items enumeration over changes enumeration.
            shouldReenumerateItems = .recoveryResync
            performFullResync()
        } else {
            performFullResync(onlyIfPreviouslyInterrupted: true)
        }
    }

    func startLoggedOut() async {
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

    @MainActor
    private func processLoginResult(_ result: LoginResult, createFreshSyncLocation: Bool, generation: UUID) async {
        guard await waitForPendingSignOut(), generation == sessionGeneration else { return }
        switch result {
        case .dismissed:
            self.loginManager = nil
        case .loggedIn(let loginData):
            await processLoginData(loginData, createFreshSyncLocation: createFreshSyncLocation)
            Log.info("AppCoordinator - loggedIn", domain: .application)
        case .signedUp:
            fatalError("Signup unimplemented")
        }
    }

    @MainActor
    private func processLoginData(_ userData: LoginData, createFreshSyncLocation: Bool) async {
        let generation = beginSession()
        await menuBarCoordinator?.showActivityIndicator()

        updatePMAPIServiceSessionUID(sessionUID: userData.credential.sessionID)
        do {
            try await storeUserData(userData, generation: generation)
            try checkSession(generation)
        } catch {
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            await menuBarCoordinator?.hideActivityIndicator()
            Log.error("AppCoordinator - store userData failed", error: error, domain: .application)
            await self.performEmergencyLogout(becauseOf: error)
            return
        }

        Log.info("AppCoordinator - storeUserData succeeded", domain: .application)
        self.initialServices.featureFlagsRepository.setUserId(userData.user.ID)
        await self.fetchFeatureFlags()
        guard generation == sessionGeneration, !Task.isCancelled else { return }

        do {
            try await self.didLogin(wantsFreshDomain: createFreshSyncLocation)
        } catch {
            await menuBarCoordinator?.hideActivityIndicator()
            Log.error("AppCoordinator - didLogin failed", error: error, domain: .application)
        }
    }

    // Required if we ever add multi-session support or switch from PMAPIClient to AuthHelper as our AuthDelegate
    private func updatePMAPIServiceSessionUID(sessionUID: String) {
        initialServices.networkService.setSessionUID(uid: sessionUID)
    }

    @MainActor
    private func storeUserData(_ data: UserData, generation: UUID) async throws {
        let store: SessionStore = initialServices.sessionVault
        let sessionRelatedCommunicator = initialServices.sessionRelatedCommunicator
        let parentSessionCredentials = data.getCredential

        try await sessionRelatedCommunicator.fetchNewChildSession(parentSessionCredential: parentSessionCredentials)
        try checkSession(generation)

        store.storeCredential(CoreCredential(parentSessionCredentials))
        store.storeUser(data.user)
        store.storeAddresses(data.addresses)
        store.storePassphrases(data.passphrases)

        await sessionRelatedCommunicator.onChildSessionReady()
    }

    @MainActor
    private func performEmergencyLogout(becauseOf error: any Error) async {
        // in case of error, the file provider won't work at all
        // therefore we retry the login
        let generation = await signOutSession()
        guard generation == sessionGeneration else { return }
        await showLoginWindow()
    }

    @MainActor
    func didLogin(wantsFreshDomain: Bool = false) async throws {
        guard await waitForPendingSignOut() else { return }
        let generation = beginSession()
        await menuBarCoordinator?.showActivityIndicator()

        do {
            try await self.domainOperationsService.identifyCurrentDomain(generation: generation)
            try checkSession(generation)
            let postLoginServices = await preparePostLoginServices()

            // The lock check is protective: a network failure must not fail a login that would
            // succeed on cached state. Non-network errors still propagate.
            async let cleanupTask: () = { [domainOperationsService] in
                do {
                    try await postLoginServices.tower.cleanUpLockedVolumeIfNeeded(using: domainOperationsService)
                } catch where error.isNetworkIssueError || (error as NSError).domain == NSURLErrorDomain {
                    Log.warning("Login volume-lock check failed with a network error; continuing login", domain: .application)
                }
            }()
            async let ffRepoFetch: ()? = try? FeatureFlagsRepository.shared.fetchFlags()
            async let ffTowerStart: ()? = try? postLoginServices.tower.featureFlags.startAsync()

            _ = try await (cleanupTask, ffRepoFetch, ffTowerStart)
            try checkSession(generation)

            try await continueDidLogin(postLoginServices: postLoginServices, wantsFreshDomain: wantsFreshDomain)
        } catch {
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            await errorHandler(error)
            throw error
        }
    }

    @MainActor
    private func continueDidLogin(postLoginServices: PostLoginServices, wantsFreshDomain: Bool) async throws {
        let generation = sessionGeneration
        try? await domainOperationsService.tearDownConnectionToAllDomains()
        try checkSession(generation)
        await postLoginServices.tower.cleanUpEventsAndMetadata(cleanupStrategy: domainOperationsService.cacheCleanupStrategy)
        try checkSession(generation)

        let didStartPostLoginServices: Bool
        if domainOperationsService.hasDomainReconnectionCapability {
            // Don't guess on failure: a throw means we can't tell first login from returning user.
            // Surface the error so the user retries login; don't wipe the cache or fire a resync.
            let domainExists: Bool
            do {
                domainExists = try await domainOperationsService.currentDomainExists()
                try checkSession(generation)
            } catch {
                try checkSession(generation)
                Log.error("Failed to determine whether the current domain exists", error: error, domain: .fileProvider)
                await errorHandler(error)
                throw error
            }
            if domainExists && !wantsFreshDomain {
                didStartPostLoginServices = try await reconnectExistingDomain(postLoginServices: postLoginServices)
            } else {
                didStartPostLoginServices = try await setUpFreshDomain(postLoginServices: postLoginServices,
                                                                       removingExistingDomains: wantsFreshDomain)
            }
        } else {
            didStartPostLoginServices = try await setUpDomainWithoutReconnection(postLoginServices: postLoginServices)
        }
        guard didStartPostLoginServices else { return }
        try checkSession(generation)

        self.didStartPostLoginServices = true
        subscriptionService.fetchSubscription(state: appState)
        appState.setLaunchCompletion(100)

        await menuBarCoordinator?.hideActivityIndicator()
    }

    /// Existing same-user domain: keep it disconnected and let the full resync reconnect it at
    /// reenumeration. Returns false when post-login services failed (handled internally).
    @MainActor
    private func reconnectExistingDomain(postLoginServices: PostLoginServices) async throws -> Bool {
        let generation = sessionGeneration
        do {
            try await postLoginServices.tower.bootstrapIfNeeded()
            try checkSession(generation)
        } catch {
            try checkSession(generation)
            await errorHandler(error)
            throw error
        }
        let migrated: Bool
        do {
            migrated = try await startPostLoginServices(postLoginServices: postLoginServices, skipSetUpDomain: true)
        } catch {
            // we ignore the error because it's handled internally in startPostLoginServices
            return false
        }
        try checkSession(generation)
        if !migrated { startLoginReconnectionResync() }
        return true
    }

    /// Fires the login-reconnection full resync: it reconnects the existing (still disconnected) domain
    /// at reenumeration and clears keepDomainDisconnectedForCacheRebuild once the rebuild succeeds.
    /// Shared by first-login reconnection and the interrupted-reconnection auto-resume on relaunch.
    @MainActor
    private func startLoginReconnectionResync() {
        // No onTerminalFailure handler here: a failed login resync surfaces its error in the resync UI,
        // which offers Retry and "Create new sync folder" (the latter runs
        // offerCreateFreshDomainAfterFailedReconnect). Recovery stays user-driven, never automatic.
        fullResyncCoordinator?.performFullResync(
            trigger: .loginReconnectionStarted,
            onReenumerationWillBegin: { [weak self] in
                // Flag lifecycle: true = the cache rebuild is incomplete. Cleared exactly here, once
                // the node-refresh rebuild succeeded and reenumeration is about to begin. It is never
                // re-set to true on failure: a failure after this point is benign (the DB is fresh and
                // the domain stays reconnected to correct data); a failure before this point leaves it
                // true, and recovery is surfaced by the resync UI.
                self?.domainOperationsService.keepDomainDisconnectedForCacheRebuild = false
            }
        )
    }

    /// No existing same-user domain (or a fresh one was requested): optionally remove existing domains,
    /// then clean, bootstrap and add a fresh domain. Returns false when post-login services failed.
    @MainActor
    private func setUpFreshDomain(postLoginServices: PostLoginServices, removingExistingDomains: Bool = false) async throws -> Bool {
        let generation = sessionGeneration
        do {
            if removingExistingDomains {
                try await domainOperationsService.removeAllDomains()
                try checkSession(generation)
            }
            await postLoginServices.tower.cleanUpEventsAndMetadata(cleanupStrategy: .cleanEverything)
            // The cleanup above only reaches the anchors of enabled loops, and a Tower built during login
            // has none; without this the new domain would poll from the previous session's cursor.
            postLoginServices.tower.discardPersistedEventsState()
            try checkSession(generation)
            try await postLoginServices.tower.bootstrapIfNeeded()
            try checkSession(generation)
            domainOperationsService.keepDomainDisconnectedForCacheRebuild = false
        } catch {
            try checkSession(generation)
            await errorHandler(error)
            throw error
        }
        do {
            try await startPostLoginServices(postLoginServices: postLoginServices, skipSetUpDomain: false)
        } catch {
            // we ignore the error because it's handled internally in startPostLoginServices
            return false
        }
        return true
    }

    /// Domain reconnection unavailable: bootstrap and set up the domain directly.
    /// Returns false when post-login services failed (handled internally).
    @MainActor
    private func setUpDomainWithoutReconnection(postLoginServices: PostLoginServices) async throws -> Bool {
        let generation = sessionGeneration
        do {
            // Reached only when cacheCleanupStrategy was .cleanEverything, so continueDidLogin already
            // wiped the metadata and bootstrap below rebuilds it — a surviving cursor is never valid
            // here. That cleanup ran on a Tower with no enabled loops, so it left the cursor behind.
            postLoginServices.tower.discardPersistedEventsState()
            try await postLoginServices.tower.bootstrapIfNeeded()
            try checkSession(generation)
        } catch {
            try checkSession(generation)
            await errorHandler(error)
            throw error
        }
        do {
            try await startPostLoginServices(postLoginServices: postLoginServices, skipSetUpDomain: false)
        } catch {
            // we ignore the error because it's handled internally in startPostLoginServices
            return false
        }
        return true
    }

    /// Recovers from a failed login reconnection by discarding the domain and re-creating it fresh:
    /// remove all domains, wipe local metadata, bootstrap, add a new domain, then dismiss the resync UI.
    @MainActor
    func offerCreateFreshDomainAfterFailedReconnect() async {
        guard pendingSignOut == nil, !Task.isCancelled else { return }
        guard !isCreatingFreshDomain else {
            Log.info("Ignoring create-fresh-domain request: one is already in progress", domain: .fileProvider)
            return
        }
        guard let tower = self.tower else {
            Log.error("Cannot create a fresh domain: post-login services are not available", domain: .fileProvider)
            return
        }
        let generation = beginSession()
        isCreatingFreshDomain = true
        defer { isCreatingFreshDomain = false }
        // Freeze the recovery buttons for the whole operation: switch the resync UI to the buttonless
        // "preparing" screen so the user can't fire a second create-new (or retry/cancel) while this runs.
        appState.fullResyncState = .starting
        do {
            try await domainOperationsService.removeAllDomains()
            try checkSession(generation)
            try await tower.recreateEmptyStoresForFreshStart()
            // Recreating the stores replaces the DB files but leaves the cursor in the app group behind.
            tower.discardPersistedEventsState()
            try checkSession(generation)
            hasPostMigrationStepRun = nil
            MigrationDetector().postMigrationCleanupIsComplete()
            FullResyncCoordinator.deletePrewipeResyncSnapshot() // recovery abandoned for a fresh domain
            try await tower.bootstrapIfNeeded()
            try checkSession(generation)
            domainOperationsService.keepDomainDisconnectedForCacheRebuild = false
            try await domainOperationsService.setUpDomain(generation: generation)
            try checkSession(generation)
            startObservingGlobalProgress()
            fullResyncCoordinator?.finishFullResync()
        } catch {
            guard generation == sessionGeneration, !Task.isCancelled else { return }
            // Move off the buttonless .starting screen: it's `isHappening`, so without this the tray stays
            // stuck on "Setting things up…" with no affordance once the login window is dismissed. .errored
            // restores the recovery buttons (Retry / Create new sync folder).
            appState.fullResyncState = .errored(error.localizedDescription)
            await errorHandler(error)
        }
    }

    private func completeOnboarding() {
        openDriveFolder()
        initializationCoordinator = nil
        onboardingCoordinator = nil
    }

    @MainActor
    private func errorHandler(_ error: any Error) async {
        let generation = await signOutSession()
        guard generation == sessionGeneration else { return }
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

    @MainActor
    private func preparePostLoginServices() -> PostLoginServices {
        Log.trace()
        didStartPostLoginServices = false
        let remoteChangeSignaler = makeRemoteChangeSignaler()
        let volumeLockEventsListener = volumeLockLifecycleController.makeEventsListener()
        // Resolved lazily: the coordinator is created below.
        let refreshEventResyncSignaler = RefreshEventResyncSignaler { [weak self] _ in
            self?.startRefreshEventResync()
        }
        Log.trace("postLoginServicesBuilder.build")
        let postLoginServices = self.postLoginServicesBuilder.build(with: [volumeLockEventsListener, remoteChangeSignaler, refreshEventResyncSignaler], activityObserver: { [weak self] in self?.currentActivityChanged($0)
        })
        self.postLoginServices = postLoginServices
        let syncStateDelegate = SyncStateDelegate(
            eventsProcessor: postLoginServices.tower,
            domainOperationsService: domainOperationsService
        )
        self.syncStateDelegate = syncStateDelegate
        volumeLockLifecycleController.setSyncStateDelegate(syncStateDelegate)
        Log.trace("configureDocumentController")
        configureDocumentController(with: postLoginServices.tower)
        self.fullResyncCoordinator = makeFullResyncCoordinator(
            applicationEventObserver,
            domainOperationsService,
            menuBarCoordinator,
            { @MainActor [weak self] in
                guard let self else { return }
                // Opening Finder before enumeration improves reliability, but it comes frontmost and
                // dismisses the tray. If the tray was open, re-show it afterwards so it stays visible
                // through the resync. The brief delay lets Finder settle before we re-activate.
                let trayWasOpen = self.mainWindowCoordinator?.isOpen == true
                await self.openDriveFolderAndWait()
                if trayWasOpen {
                    try? await Task.sleep(for: .milliseconds(400))
                    self.showStatusWindow(from: nil)
                }
            },
            { [weak self] in self?.featureFlags?.isEnabled(flag: .driveMacRefreshEventResyncDisabled) == true },
            postLoginServices.tower
        )
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

    @MainActor
    @discardableResult
    private func startPostLoginServices(postLoginServices: PostLoginServices, skipSetUpDomain: Bool = false) async throws -> Bool {
        let generation = sessionGeneration
        guard self.postLoginServices === postLoginServices else { throw CancellationError() }
        Log.trace()
        self.launchOnBoot.userSignedIn()
        self.initialServices.localSettings.userId = client?.credentialProvider.clientCredential()?.userID

        postLoginServices.onLaunchAfterSignIn()
        do {
            let migrated: Bool

            do {
                migrated = try await performPostMigrationStep(postLoginServices)
                try checkSession(generation)
            } catch {
                try checkSession(generation)
                Log.error("PostMigrationStep failed", error: error, domain: .application)
                throw DomainOperationErrors.postMigrationStepFailed(error)
            }

            if !migrated && !skipSetUpDomain {
                try await domainOperationsService.setUpDomain(generation: generation)
                try checkSession(generation)
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
            guard let syncStateDelegate else {
                throw NSError(domain: "me.proton.drive", code: 0, localizedDescription: "Sync state delegate unavailable")
            }

            async let syncObserverTask = SyncDBObserver(
                state: appState,
                syncStorageManager: postLoginServices.tower.syncStorage,
                syncStateDelegate: syncStateDelegate,
                testRunner: testRunner)

            let syncObserver = await syncObserverTask
            try checkSession(generation)

            applicationEventObserver.configurePostLoginServices(
                syncObserver: syncObserver,
                sessionVault: postLoginServices.tower.sessionVault,
                settingsService: postLoginServices.tower.generalSettings,
                featureFlagProvider: postLoginServices.tower.featureFlags
            )
            startObservingGlobalProgress()

            let hasPlan = initialServices.sessionVault.userInfo?.hasAnySubscription
            DriveIntegrityErrorMonitor.configure(with: Constants.appGroup, forUserWithPlan: hasPlan)
            return migrated
        } catch {
            try checkSession(generation)
            // Keep recovery markers until refresh or a completed fresh-store reset discharges them.
            // Sign-out can itself be interrupted and must not erase an unfinished rebuild.
            // if the user logs out, we no longer need to tell them we're syncing
            await menuBarCoordinator?.hideActivityIndicator()
            try checkSession(generation)
            Log.error("PostLoginServicesErrors", error: error, domain: .fileProvider)
            let signoutGeneration = await signOutSession()
            guard signoutGeneration == sessionGeneration else { throw CancellationError() }
            let loginError = error.asLoginError(with: error.localizedDescription)
            await showLoginWindow(initialError: loginError)
            throw error
        }
    }

    @MainActor
    func setUpApplicationEventObserver() async {
        Log.trace()

        appState.setAccountInfo(self.initialServices.sessionVault.getAccountInfo())

        applicationEventObserver.startObserving()

        self.menuBarCoordinator = await MenuBarCoordinator(
            state: appState,
            userActions: UserActions(delegate: self),
            isFullResyncPausable: { [weak self] in
                // A login-reconnection resync must not be pausable.
                self?.fullResyncCoordinator?.resyncTrigger.isLoginReconnection != true
            },
            isFullResyncCancellable: { [weak self] in
                self?.fullResyncCoordinator?.resyncTrigger.isRefreshEvent != true
            })
    }

    @MainActor
    private func performPostMigrationStep(_ postLoginServices: PostLoginServices) async throws -> Bool {
        let generation = sessionGeneration
        Log.info("Begin post-migration step", domain: .application)
        let migrationDetector = MigrationDetector()
        let migrationPerformer = MigrationPerformer()

        if GroupContainerMigrator.instance.hasGroupContainerMigrationHappened {
            migrationDetector.groupContainerMigrationHappened()
        }

        guard hasPostMigrationStepRun == false || migrationDetector.requiresPostMigrationStep else {
            hasPostMigrationStepRun = nil
            Log.info("No post-migration cleanup is required", domain: .application)
            return false
        }

        // The rollout flag controls starting cleanup, not finishing an existing obligation.
        guard hasPostMigrationStepRun == false
                || postLoginServices.tower.featureFlags.isEnabled(flag: .postMigrationJunkFilesCleanup) else {
            Log.info("No feature flag enabled for post-migration cleanup", domain: .application)
            return false
        }

        guard initialServices.networkClient.isReachable() else {
            if hasPostMigrationStepRun == false {
                let message = "Network connection not available while post-migration has not finished"
                Log.error(message, domain: .application)
                let error = NSError(domain: "me.proton.drive", code: 0, localizedDescription: message)
                throw DomainOperationErrors.postMigrationStepFailed(error)
            }
            Log.warning("Machine is offline, skipping post-migration cleanup till next app launch", domain: .application)
            return false
        }

        // An unfinished cleanup already established the obligation; no need to inspect the wiped DB.
        guard try hasPostMigrationStepRun == false
                || migrationPerformer.hasFaultyNodes(in: postLoginServices.tower.storage.mainContext) else {
            Log.info("No junk found in local DB, skipping post-migration cleanup", domain: .application)
            migrationDetector.postMigrationCleanupIsComplete()
            return false
        }

        Log.info("Faulty nodes detected, will perfom post-migration cleanup", domain: .application, sendToSentryIfPossible: true)

        hasPostMigrationStepRun = false

        // Drop system FileProvider cache
        postLoginServices.tower.pauseEventsSystem()
        try await domainOperationsService.disconnectAllDomainsDuringMainKeyCleanup()
        try checkSession(generation)

        await menuBarCoordinator?.showActivityIndicator()

        try await migrationCleanup(postLoginServices.tower)
        try checkSession(generation)
        try await refreshUsingSyncApproach(tower: postLoginServices.tower)
        try checkSession(generation)

        await menuBarCoordinator?.hideActivityIndicator()

        // Clear the flag before reconnecting: connectCurrentDomain() skips reconnection while it is set.
        domainOperationsService.keepDomainDisconnectedForCacheRebuild = false
        do {
            try await domainOperationsService.connectCurrentDomain(generation: generation)
            try checkSession(generation)

            // this causes the file provider to enumerate items
            shouldReenumerateItems = .recoveryResync
            try await domainOperationsService.signalEnumerator(reason: .postMigration)
            try checkSession(generation)
        } catch {
            if generation == sessionGeneration {
                domainOperationsService.keepDomainDisconnectedForCacheRebuild = true
            }
            throw error
        }

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
    @MainActor
    func showInitializationWindow() -> InitializationCoordinator {
        signInStep = .initialization
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
    }
}

// MARK: - Session and progress lifecycle

extension AppCoordinator {
    /// Replace the session token so AppCoordinator can reject stale startup and sign-out continuations
    /// before they install progress observation or clear replacement services.
    /// DomainOperationsService separately coordinates physical domain removals with discovery.
    @MainActor
    @discardableResult
    private func beginSession() -> UUID {
        initializationCoordinator?.cancelPendingRetry()
        migrationCancelToken?.cancel()
        migrationCancelToken = nil
        sessionGeneration = UUID()
        domainOperationsService.useSessionGeneration(sessionGeneration)
        applicationEventObserver.stopObservingProgress()
        return sessionGeneration
    }

    /// Wait for the teardown attempt to settle, including its failure path. A newer session
    /// owns presentation if another caller wins the main actor before this waiter resumes.
    @MainActor
    private func waitForPendingSignOut() async -> Bool {
        let generation = sessionGeneration
        if let pendingSignOut { _ = await pendingSignOut.value }
        return generation == sessionGeneration && !Task.isCancelled
    }

    @MainActor
    private func checkSession(_ generation: UUID) throws {
        guard generation == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
    }

    /// Global progress is presentation-only: an unresolvable domain must degrade progress
    /// reporting, never fail login or abandon a resync.
    @MainActor
    private func startObservingGlobalProgress() {
        guard let domain = try? domainOperationsService.requireCurrentDomain() else {
            Log.warning(
                "No current domain — global progress will not be reported",
                domain: .application
            )
            applicationEventObserver.stopObservingProgress()
            return
        }
        applicationEventObserver.startObservingProgress(for: domain)
    }
}

// MARK: - Sign out

#if HAS_QA_FEATURES
extension AppCoordinator: SignoutManager {}
#endif

extension AppCoordinator: VolumeLockLifecycleDelegate {
    var volumeLockResolver: VolumeLockResolving? {
        postLoginServices?.tower
    }

    func startPostLoginServices() async throws {
        guard let postLoginServices else { return }
        try await continueLoggedInStartup(postLoginServices: postLoginServices)
    }

    /// The domain is never removed, only disconnected — removing and re-adding it would leave the OS
    /// with enumeration state keyed to the dead root. The login-reconnection resync reconnects it.
    func recoverLockedVolumeReplacingLocalState() async throws {
        guard let postLoginServices else {
            throw NSError(
                domain: "me.proton.drive",
                code: 0,
                localizedDescription: "No post-login services during volume-lock recovery"
            )
        }
        let tower = postLoginServices.tower
        let generation = sessionGeneration

        // Wiping the store an active resync snapshotted corrupts it, and the coordinator's
        // single-flight would silently drop our rebuild trigger; terminal states are safe.
        switch appState.fullResyncState {
        case .starting, .inProgress, .enumerating, .paused:
            Log.warning("Volume-lock recovery deferred: a resync is active; the poll will retry", domain: .application)
            throw NSError(
                domain: "me.proton.drive",
                code: 0,
                localizedDescription: "Volume-lock recovery deferred while a resync is active"
            )
        case .idle, .completed, .errored:
            break
        }

        // A sign-out inside any await below nils `self.postLoginServices`; abort rather than
        // restart services on a dead session.
        func guardSessionStillCurrent() throws {
            try checkSession(generation)
            guard self.postLoginServices === postLoginServices else {
                Log.warning("Volume-lock recovery aborted: the session changed mid-recovery", domain: .application)
                throw NSError(
                    domain: "me.proton.drive",
                    code: 0,
                    localizedDescription: "Session changed during volume-lock recovery"
                )
            }
        }

        // The wipe creates the same rebuild-pending state a reconnection sign-out leaves behind, so mark
        // it like one: the flag routes cancel-before-rebuild to the resync recovery UI, blocks stray
        // domain reconnects against the root-only DB, and lets launch auto-resume an interrupted rebuild
        // (FF-gated; with the FF off the domain stays disconnected until a rebuild clears the flag —
        // safer than connecting an empty DB). The login-reconnection resync clears it on success;
        // after an aborted recovery it deliberately stays set until a rebuild or sign-out clears it.
        domainOperationsService.keepDomainDisconnectedForCacheRebuild = true

        // Snapshot the node IDs before the wipe so the resync can signal the old nodes as deletions.
        await FullResyncCoordinator.handleResyncSnapshotBeforeWipe(from: tower.storage)
        try guardSessionStillCurrent()

        await tower.cleanUpEventsAndMetadata(cleanupStrategy: .cleanEverythingButUserSpecificSettings)
        // Local state is replaced wholesale; the login-reconnection resync below sets a fresh cursor.
        tower.discardPersistedEventsState()
        try guardSessionStillCurrent()

        // The resync fetches its own root into the recovery DB, but services run against the main DB
        // before the swap and need a root there.
        try await tower.bootstrapIfNeeded()
        try guardSessionStillCurrent()

        // The resync coordinator only exists once services are up. skipSetUpDomain: the DB is
        // root-only; the resync reconnects the domain at reenumeration (same contract as login).
        var migrated = false
        if !didStartPostLoginServices {
            migrated = try await startPostLoginServices(postLoginServices: postLoginServices, skipSetUpDomain: true)
            try guardSessionStillCurrent()
            didStartPostLoginServices = true
            subscriptionService.fetchSubscription(state: appState)
        }

        // A pending migration may already have completed this rebuild while starting services.
        guard !migrated else { return }

        // Not gated on hasDomainReconnectionCapability: login's gate discriminates what sign-out left
        // behind (FF off leaves no domain to reconnect); this path manufactures the reconnect-pending
        // state itself, and only the login-reconnection resync can finish it — FF on or off.
        // MUST be the last statement (fire-and-forget): the controller clears the lock synchronously
        // right after we return, or the resync's pushes resolve to the lock and keep the domain paused.
        startLoginReconnectionResync()
    }
}

extension AppCoordinator {

    @MainActor
    func signOutAsync() async {
        _ = await signOutSession()
    }

    @MainActor
    private func signOutSession() async -> UUID {
        if let pendingSignOut { return await pendingSignOut.value }

        let generation = beginSession()
        let forceRemoveDomain = forceRemoveDomainOnSignOut == true
        forceRemoveDomainOnSignOut = nil
        // The coordinator owns teardown. Cancelling one caller must not abandon cleanup or
        // let another login write credentials while the old account is still being cleared.
        let task = Task { @MainActor in
            applicationEventObserver.stopMonitoring(dueToSignOut: true)
            await volumeLockLifecycleController.reset()
            await signOutAsync(domainOperationsService: domainOperationsService,
                               generation: generation, forceRemoveDomain: forceRemoveDomain)
            didLogout()
            pendingSignOut = nil
            return generation
        }
        pendingSignOut = task
        return await task.value
    }

    @MainActor
    private func signOutAsync(domainOperationsService: DomainOperationsServiceProtocol, generation: UUID, forceRemoveDomain: Bool) async {
        if let tower = postLoginServices?.tower {
            // Remove the domain entirely when the user asked to, otherwise just disconnect the extension.
            if forceRemoveDomain {
                try? await domainOperationsService.removeAllDomains()
            } else {
                try? await domainOperationsService.tearDownConnectionToAllDomains()
            }
            guard generation == sessionGeneration else { return }
            // Match the cache cleanup to the domain action so we don't leave an orphaned cache behind.
            await tower.destroyCache(strategy: forceRemoveDomain ? .cleanEverything : domainOperationsService.cacheCleanupStrategy)
            guard generation == sessionGeneration else { return }
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
        guard generation == sessionGeneration else { return }
        initialServices.sessionVault.signOut()
        initialServices.sessionRelatedCommunicator.clearStateOnSignOut()

        // remove session from networking object when signing out
        initialServices.networkService.sessionUID = ""
    }

    @MainActor
    private func didLogout() {
        configureDocumentController(with: nil)
        postLoginServices = nil
        syncStateDelegate = nil
        activityService = nil
        didStartPostLoginServices = false

        FullResyncCoordinator.deletePrewipeResyncSnapshot() // clear any in-flight recovery snapshot
        FullResyncCoordinator.clearRefreshEventResyncTag()
        launchOnBoot.userSignedOut()
        dismissAnyOpenWindows()
    }
}

// MARK: - Window handling

extension AppCoordinator {

    /// Create and return new window.
    private func createWindow() -> NSWindow {
        let appWindow = NSWindow()
        appWindow.isReleasedWhenClosed = false
        appWindow.styleMask = [.titled, .closable, .miniaturizable]
        appWindow.titlebarAppearsTransparent = true
        appWindow.backgroundColor = ColorProvider.BackgroundNorm
        appWindow.delegate = self
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

    @MainActor
    private func dismissAnyOpenWindows() {
        loginManager = nil
        signInStep = nil
        initializationCoordinator = nil
        onboardingCoordinator = nil

        // Finish closing the old window before sign-in can install its replacement.
        window?.close()
        window = nil

        settingsWindowCoordinator?.stop()
        settingsWindowCoordinator = nil

#if HAS_QA_FEATURES
        qaSettingsWindowCoordinator?.stop()
        qaSettingsWindowCoordinator = nil
#endif

        syncErrorWindowCoordinator?.stop()
        syncErrorWindowCoordinator = nil

        mainWindowCoordinator?.stop()
        mainWindowCoordinator = nil
    }

    @MainActor
    private func refreshUsingSyncApproach(tower: Tower) async throws {
        let generation = sessionGeneration
        let coordinator = showInitializationWindow()
        defer {
            if generation == sessionGeneration { coordinator.cancelPendingRetry() }
        }
        while true {
            try checkSession(generation)
            coordinator.update(progress: .init())
            let cancelToken = CancelToken()
            migrationCancelToken = cancelToken
            defer {
                if migrationCancelToken === cancelToken { migrationCancelToken = nil }
            }
            do {
                let report = try await withTaskCancellationHandler {
                    try await migrationRefresh(tower, cancelToken)
                } onCancel: {
                    cancelToken.cancel()
                }
                try checkSession(generation)
                guard report.failed == 0 else {
                    throw NSError(domain: "me.proton.drive", code: 0,
                                  localizedDescription: "Setup could not refresh all items. Please retry.")
                }
                migrationCancelToken = nil
                return
            } catch {
                try checkSession(generation)
                migrationCancelToken = nil
                guard await coordinator.waitForRetry(after: error) else { throw CancellationError() }
                try checkSession(generation)
            }
        }
    }

    @MainActor
    static func refreshMigrationMetadata(tower: Tower, cancelToken: CancelToken) async throws -> RefreshedNodesReport {
        let moc = tower.storage.backgroundContext
        let rootFolder = try await tower.rootFolder(moc: moc)
        let volumeID = try tower.storage.getMyVolumeId(in: moc)
        return try await tower.refresher.refreshUsingSyncApproach(
            root: rootFolder, volumeID: volumeID, cancelToken: cancelToken, onNodesRefreshed: { _, _ in }
        )
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
            Task { @MainActor [weak self] in
                await self?.userRequestedSignOut()
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

    /// Presents a destructive confirmation. The destructive button is added first, so it is the primary
    /// (default) button and runs `onConfirm`; the "continue" button is added second and stays grey. When
    /// `accessoryView` is provided it replaces `informativeText` (used for a body with an inline link).
    private func presentDestructiveConfirmation(
        title: String,
        informativeText: String = "",
        confirmButtonText: String,
        cancelButtonText: String,
        accessoryView: NSView? = nil,
        onConfirm: () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        if let accessoryView {
            alert.accessoryView = accessoryView
        } else {
            alert.informativeText = informativeText
        }

        let confirmButton = alert.addButton(withTitle: confirmButtonText)
        confirmButton.hasDestructiveAction = true
        alert.addButton(withTitle: cancelButtonText)

        if alert.runModal() == .alertFirstButtonReturn {
            onConfirm()
        }
    }

    /// A non-editable text view for an alert body ending in a clickable "Learn more" link. The text view
    /// opens the link itself (default NSTextView behavior), so the alert stays up while the guide opens.
    private func confirmationBody(_ body: String, linkText: String, url: URL) -> NSView {
        let width: CGFloat = 240
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSMutableAttributedString(
            string: body + " ",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        text.append(NSAttributedString(
            string: linkText,
            attributes: [.font: font, .foregroundColor: NSColor.linkColor, .link: url]
        ))
        textView.textStorage?.setAttributedString(text)

        if let container = textView.textContainer, let layout = textView.layoutManager {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            textView.frame = NSRect(x: 0, y: 0, width: width, height: ceil(layout.usedRect(for: container).height))
        }
        return textView
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
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === window else { return }
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
                try await applicationEventObserver.refreshItems()
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
                userActions: userActions,
                resyncButtonContext: { [weak self] in
                    // A login/domain-reconnection resync runs against a disconnected domain: not pausable,
                    // Cancel can't return to a working state, so recovery offers "create a new sync folder".
                    // An automatic (refresh-event) resync is pausable but not cancellable while it runs.
                    // A user-initiated resync keeps a working domain: pausable and cancellable.
                    guard let trigger = self?.fullResyncCoordinator?.resyncTrigger else { return .userInitiated }
                    if trigger.isLoginReconnection { return .loginReconnection }
                    if trigger.isRefreshEvent { return .automatic }
                    return .userInitiated
                }
            )
        }
    }

    func closeOnboardingWindow() {
        Task { @MainActor in
            self.onboardingCoordinator?.end()
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

    @MainActor
    func userRequestedSignOut() async {
        let generation = await signOutSession()
        guard generation == sessionGeneration, !Task.isCancelled else { return }
        await showLoginWindow()
    }

    @MainActor
    func userRequestedSignOutRemovingDomain() async {
        // A duplicate request joins the policy already chosen for this teardown.
        if pendingSignOut == nil { forceRemoveDomainOnSignOut = true }
        await userRequestedSignOut()
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
            try await self?.applicationEventObserver.pauseSyncing()
        }
    }

    func resumeSyncing() {
        performWithLogging { [weak self] in
            guard let self else { return }
            if self.appState.isVolumeLocked {
                // While locked, sync is effectively paused by the lock; "resume" means "check whether
                // the volume was recovered" — the same reconciliation the recovery poll runs, on demand.
                await self.menuBarCoordinator?.showActivityIndicator()
                do {
                    try await self.volumeLockLifecycleController.reconcile(trigger: .userResume)
                } catch {
                    await self.menuBarCoordinator?.hideActivityIndicator()
                    throw error
                }
                await self.menuBarCoordinator?.hideActivityIndicator()
            } else {
                try await self.applicationEventObserver.resumeSyncing()
            }
        }
    }

    func togglePausedStatus() {
        performWithLogging { [weak self] in
            try await self?.applicationEventObserver.togglePausedStatus()
        }
    }

    func cleanUpErrors() async {
        await applicationEventObserver.cleanUpErrors()
        domainOperationsService.cleanUpErrors()
    }

    func signInUsingTestCredentials(login: String, password: String) {
        Task { @MainActor in
            loginManager?.logIn(as: login, password: password)
        }
    }

    @MainActor
    func performFullResync(onlyIfPreviouslyInterrupted: Bool = false) {
        // A resync against a locked volume is doomed, and its in-progress state would mask the
        // locked surfaces. Recovery's rebuild bypasses this via startLoginReconnectionResync.
        guard !appState.isVolumeLocked else {
            Log.info("Ignoring full resync request while the volume is locked", domain: .application)
            return
        }
        // The tray hides its entry points while a resync is on screen, but an already-open Settings
        // window does not — and .errored clears fullResyncInProgress, so single-flight misses it.
        guard !appState.fullResyncState.isHappening else {
            Log.info("Ignoring full resync request because one is already on screen: \(appState.fullResyncState.statusName)",
                     domain: .resyncing)
            return
        }
        fullResyncCoordinator?.performFullResync(onlyIfPreviouslyInterrupted: onlyIfPreviouslyInterrupted)
    }

    /// Entry point for `Refresh == 1`. Not `performFullResync`, which starts a `.userStarted` resync.
    @MainActor
    private func startRefreshEventResync() {
        guard featureFlags?.isEnabled(flag: .driveMacRefreshEventResyncDisabled) != true else {
            Log.info("Backend requested an events refresh but the refresh-event resync is disabled", domain: .resyncing)
            return
        }
        guard !appState.isVolumeLocked else {
            // Volume-lock recovery rebuilds local state itself.
            Log.info("Ignoring the events refresh request while the volume is locked", domain: .application)
            return
        }
        Log.info("Backend requested an events refresh; starting a full resync",
                 domain: .resyncing, sendToSentryIfPossible: true)
        fullResyncCoordinator?.performFullResync(trigger: .refreshEventStarted)
    }

    func confirmFullResync() -> Bool {
        var confirmed = false
        presentConfirmationDialog(
            messageText: Localization.full_resync_confirm_title,
            informativeText: Localization.full_resync_confirm_body,
            actionButtonText: Localization.full_resync_confirm_action
        ) {
            confirmed = true
        }
        return confirmed
    }

    func finishFullResync() {
        fullResyncCoordinator?.finishFullResync()
    }

    @MainActor
    func retryFullResync() {
        fullResyncCoordinator?.retryFullResync()
    }

    /// Cancelling throws away the resync's progress, so confirm first (destructive). Applies to every
    /// Cancel button — running, paused, or errored, user-initiated or login-reconnection.
    ///
    /// `NSAlert.runModal()` spins the run loop in a common mode, so the resync keeps advancing while the
    /// alert is up and can pass the point where cancelling is safe (stores swapped, domain reconnected).
    /// The phase captured at tap time is therefore re-checked on confirm, and a stale confirmation is
    /// dropped rather than tearing down a resync that has moved on. Compared by `phase`, not by value, so
    /// ordinary progress ticks within the same phase still allow the cancel.
    private func confirmCancelResync(then cancel: @escaping () -> Void) {
        let phaseAtRequest = appState.fullResyncState.phase
        presentDestructiveConfirmation(
            title: Localization.full_resync_cancel_confirm_title,
            informativeText: Localization.full_resync_cancel_confirm_body,
            confirmButtonText: Localization.full_resync_cancel_confirm_action,
            cancelButtonText: Localization.full_resync_continue
        ) { [weak self] in
            guard let self else { return }
            guard self.appState.fullResyncState.phase == phaseAtRequest else {
                Log.info("Ignoring stale resync cancellation: the resync moved on while the confirmation was up",
                         domain: .resyncing)
                return
            }
            cancel()
        }
    }

    func cancelFullResync() {
        confirmCancelResync { self.fullResyncCoordinator?.cancelFullResync() }
    }

    func pauseFullResync() {
        fullResyncCoordinator?.pauseFullResync()
    }

    @MainActor
    func resumeFullResync() {
        fullResyncCoordinator?.resumeFullResync()
    }

    func cancelPausedResync() {
        confirmCancelResync { self.fullResyncCoordinator?.cancelPausedResync() }
    }

    func dismissAutomaticResyncReason() {
        appState.automaticResyncReasonDismissed = true
    }

    func createNewDomainAfterFailedResync() {
        // Rebuilding re-creates the sync folder from scratch, so confirm before the destructive work. The
        // body carries an inline "Learn more" link to the folder guide; the destructive button rebuilds.
        let guideURL = URL(string: "https://proton.me/support/drive-macos-guide#access")!
        let body = confirmationBody(
            Localization.full_resync_create_new_confirm_body,
            linkText: Localization.full_resync_learn_more,
            url: guideURL
        )
        presentDestructiveConfirmation(
            title: Localization.full_resync_create_new_confirm_title,
            confirmButtonText: Localization.full_resync_create_new_location,
            cancelButtonText: Localization.full_resync_continue,
            accessoryView: body
        ) {
            Task { @MainActor in
                await self.offerCreateFreshDomainAfterFailedReconnect()
            }
        }
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
            UserActions(delegate: self).app.restartApp()
        }
    }

    @MainActor
    private func showLoginWindow(initialError: LoginError? = nil) async {
        guard await waitForPendingSignOut() else { return }
        let generation = sessionGeneration
        self.signInStep = .login
        if let loginManager = self.loginManager {
            loginManager.presentLoginFlow(
                with: initialError ?? self.driveCoreAlertListener.initialLoginError()
            )
        } else {
            let appWindow = createWindow()
            self.window = appWindow

            let loginManager = self.loginBuilder.build(
                in: appWindow,
                offersCreateFreshSyncLocation: { [weak self] in
                    self?.domainOperationsService.hasDomainReconnectionCapabilityIfKnown ?? false
                },
                completion: { [weak self] result, createFreshSyncLocation in
                    guard let self = self else { return }
                    await self.processLoginResult(result, createFreshSyncLocation: createFreshSyncLocation, generation: generation)
                }
            )

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
                    isFullResyncAlwaysVisible: { [weak self] in
                        self?.postLoginServices?.tower.featureFlags.isEnabled(flag: .driveMacFullResyncAlwaysVisibleDisabled) != true
                    },
                    offersDomainRemovalOnSignOut: { [weak self] in
                        self?.domainOperationsService.hasDomainReconnectionCapability ?? false
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
                    applicationEventObserver: applicationEventObserver,
                    metadataStorage: self.tower?.storage,
                    eventsStorage: self.tower?.eventStorageManager,
                    jailDependencies: self.client.map { (initialServices.networkService, $0) }
                )
            }
            await qaSettingsWindowCoordinator!.start()
        }
    }

    @MainActor
    func toggleGlobalProgressQaStatusItemVisibility() {
        applicationEventObserver.toggleGlobalProgressQaStatusItemVisibility()
    }

    @MainActor
    func simulateRefreshEventResync() {
        startRefreshEventResync()
    }
#endif

    func openDriveFolder(fileLocation: String? = nil) {
        Task { @MainActor in
            await openDriveFolderAndWait(fileLocation: fileLocation)
        }
    }

    /// Opens (and selects) the Drive folder in Finder, awaiting completion. Extracted so the resync flow can
    /// re-show the tray afterwards — opening Finder brings it frontmost, which dismisses the tray window.
    @MainActor
    private func openDriveFolderAndWait(fileLocation: String? = nil) async {
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

    func keepDownloaded(paths: [String]) {
        Task {
            do {
                pathsMarkedAsKeepDownloaded = try await itemIdentifierStrings(for: paths).joined(separator: ":")
                try await domainOperationsService.signalEnumerator(reason: .keepDownloadedStateChanged)
            } catch {
                Log.error("Error calling keepDownloaded from TestRunner", error: error, domain: .testRunner)
            }
        }
    }

    func keepOnlineOnly(paths: [String]) {
        Task {
            do {
                pathsMarkedAsOnlineOnly = try await itemIdentifierStrings(for: paths).joined(separator: ":")
                try await domainOperationsService.signalEnumerator(reason: .keepDownloadedStateChanged)
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

    // MARK: - Promotional actions

    func dismissPromoBanner() {
        promoCampaignInteractor.dismissCampaign()
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
