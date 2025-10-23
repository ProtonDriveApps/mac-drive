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

import Combine
import SwiftUI
import PDCore
import PDLocalization

protocol LoggedInStateReporter {
    var isLoggedIn: Bool { get }
    var isLoggedInPublisher: AnyPublisher<Bool, Never> { get }
}
extension InitialServices: LoggedInStateReporter { }

/// Observes changes to logins and logouts, network status, app update availability and file syncing, and propagates them to `ApplicationState`.
/// Subscribes to the sources of updates that are passed to the initializer, then subscribes to additional ones in "startSyncMonitoring"
///
/// The flow in the app is as follows:
/// `ApplicationEventObserver` observes all the changes happening in the app that are relevant to displaying information to the user.
/// These changes come from various sources: user actions (log in, pause/resume), the file provider (file changes), the OS (network reachable?), Timers (time since last sync) and Sparkle (update available?).
/// All changes are propagated to a single `ApplicationState` object, which aggregates all the information needed to render the UI.
/// The `MenuBarCoordinator` and SwiftUI observe changes to the ApplicationState, and update the menu and window view respectively.
///

class ApplicationEventObserver: ObservableObject {
#if HAS_QA_FEATURES
    @Published private(set) var state: ApplicationState
    @Published var syncItemHistory = [SyncHistoryItem]()

    /// Counts how many times the application state is updated, to enable detecting when it happens too much.
    static var updateCounter = 0

#else
    private(set) var state: ApplicationState
#endif

    private let deleteAlerter: DeleteAlerter

    /// Fires whenever a user logs in or out, but we only use it to detect logouts.
    private var logoutStateService: LoggedInStateReporter?

    /// Fires when the network availability changes
    private let networkStateService: NetworkStateInteractor?

    /// Fires whenever and update becomes available.
    private var appUpdateService: AppUpdateServiceProtocol?

    /// Fires whenever there is a file to sync
    private var syncObserver: SyncDBObserver?

    /// Fires when there is a global progress update
    private var globalProgressObserver: GlobalProgressObserver?

    /// Fires whenever a user logs in, and passes an `AccountInfo` object
    private var sessionVault: SessionVault?

    /// Fires every `ElapsedTimeService.timeInterval` seconds, only the dropdown Menu or Status Window are opened.
    private var elapsedTimeService: ElapsedTimeService?

    /// Fires whenever there's a change to active promo campaigns for the user.
    private var promoCampaignInteractor: PromoCampaignInteractorProtocol?

    /// Responsible for fetching user config
    private var generalSettingsService: GeneralSettings?

    private let resyncUpdateSubject = PassthroughSubject<Int, Never>()

    /// Always-on
    private var globalCancellables = Set<AnyCancellable>()
    /// Only while user is logged in
    private var userCancellables = Set<AnyCancellable>()

    init(
        state: ApplicationState,
        logoutStateService: LoggedInStateReporter?,
        networkStateService: NetworkStateInteractor?,
        appUpdateService: AppUpdateServiceProtocol?,
        promoCampaignInteractor: PromoCampaignInteractorProtocol?
    ) {
        self.state = state
        self.logoutStateService = logoutStateService
        self.networkStateService = networkStateService
        self.appUpdateService = appUpdateService
        self.promoCampaignInteractor = promoCampaignInteractor

        self.deleteAlerter = DeleteAlerter()

        setUpObservers()
    }

    deinit {
        Log.trace()
        stopMonitoring(dueToSignOut: false)
    }

    // MARK: - Public

    public func startSyncMonitoring(syncObserver: SyncDBObserver,
                                    globalProgressObserver: GlobalProgressObserver?,
                                    sessionVault: SessionVault?) async {
        Log.trace()

        self.syncObserver = syncObserver
        self.globalProgressObserver = globalProgressObserver
        self.elapsedTimeService = ElapsedTimeService(state: state)

        self.sessionVault = sessionVault

        self.globalProgressObserver?.startMonitoring()
        self.subscribeToSyncChanges()
        await self.subscribeToPassageOfTime()

        self.subscribetoLogin()
        self.subscribetoUserInfo()
    }

    public func startGeneralSettingsMonitoring(settingsService: GeneralSettings) {
        Log.trace()

        generalSettingsService = settingsService
        generalSettingsService?.fetchUserSettings()

        generalSettingsService?.userSettings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] userSettings in
                self?.state.setUserSettings(userSettings)
            }
            .store(in: &userCancellables)
    }

    /// - Parameters:
    ///   - all: stop all subscriptions, not just user-specific ones.
    public func stopMonitoring(dueToSignOut: Bool) {
        Log.trace()

        self.syncObserver = nil
        self.globalProgressObserver = nil
        self.elapsedTimeService = nil
        self.sessionVault = nil
        self.userCancellables.removeAll()
        didReceiveLogoutState(isSignedIn: false)
        if !dueToSignOut {
            self.globalCancellables.removeAll()
        }
    }

    @MainActor
    public func pauseSyncing() async throws {
        Log.trace()

        assert(syncObserver != nil)

        try await syncObserver?.updateSyncState(paused: true,
                                                offline: state.isOffline,
                                                fullResyncInProgress: state.fullResyncState.isHappening)
        state.isPaused = true
    }

    @MainActor
    public func resumeSyncing() async throws {
        Log.trace()
        
        assert(syncObserver != nil)

        try await syncObserver?.updateSyncState(paused: false,
                                                offline: state.isOffline,
                                                fullResyncInProgress: state.fullResyncState.isHappening)
        state.isPaused = false

        state.isResuming = true
        state.itemEnumerationProgress = Localization.enumerating_after_resuming
        try await Task.sleep(for: .seconds(15))
        state.isResuming = false
    }

    func waitUntilEnumerationHasBegunAndEnded() async throws {
        try await Task.sleep(for: .seconds(10))

        try await waitUntilCompleted { [weak self] in self?.state.isEnumerating ?? false }

        func waitUntilCompleted(_ isCompleted: @escaping () -> Bool) async throws {
            var pendingDuration: TimeInterval = 0

            while true {
                if !isCompleted() {
                    pendingDuration += 1
                    if pendingDuration >= 10 {
                        // Value has been false for 10 seconds
                        break
                    }
                } else {
                    pendingDuration = 0
                }

                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    @MainActor
    public func togglePausedStatus() async throws {
        Log.trace()

        if case .paused = state.overallStatus {
            try await resumeSyncing()
        } else {
            try await pauseSyncing()
        }
    }

    public func cleanUpErrors() {
        Log.trace()
        syncObserver?.cleanUpErrors()
    }

    public func refreshItems() async throws {
        Log.trace()
        try await syncObserver?.fetchItems()
    }

    @MainActor
    public func fullResyncStarted() async throws {
        try await syncObserver?.updateSyncState(paused: state.isPaused, offline: state.isOffline, fullResyncInProgress: true)
        state.fullResyncState = .inProgress(0)
    }
    
    @MainActor
    public func fullResyncItemCountUpdated(_ count: Int) {
        Log.trace()
        resyncUpdateSubject.send(count)
    }

    private func throttledFullResyncItemCountUpdated(_ count: Int) {
        Log.trace()
        state.fullResyncState = .inProgress(count)
    }
    
    @MainActor
    public func fullResyncReenumerationStarted() async throws {
        try await syncObserver?.updateSyncState(paused: state.isPaused, offline: state.isOffline, fullResyncInProgress: false)
        state.fullResyncState = .enumerating
    }
    
    @MainActor
    public func fullResyncCompleted(hasFileProviderResponded: Bool) {
        state.fullResyncState = .completed(hasFileProviderResponded: hasFileProviderResponded)
    }
    
    @MainActor
    public func fullResyncFinished()  {
        state.fullResyncState = .idle
    }
    
    @MainActor
    public func fullResyncErrored(message: String) {
        state.fullResyncState = .errored(message)
    }

    @MainActor
    public func fullResyncCancelled() async throws {
        state.fullResyncState = .idle
        try await syncObserver?.updateSyncState(paused: state.isPaused, offline: state.isOffline, fullResyncInProgress: false)
    }

    // MARK: - Private

    private func setUpObservers() {
        Log.trace()

        self.subscribeToLogout()

        self.subscribeToNetworkState()

#if HAS_BUILTIN_UPDATER
        self.subscribeToUpdateAvailability()
#endif

        self.resyncUpdateSubject
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                self?.throttledFullResyncItemCountUpdated($0)
            }
            .store(in: &globalCancellables)

        var previousState = state.properties

#if HAS_QA_FEATURES
        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] in
                let diff: [ApplicationState.Property] = Array(
                    Set(self.state.properties).subtracting(Set(previousState))
                )
                previousState = Array(self.state.properties)
                Self.updateCounter += 1
                Log.trace("Received state.objectWillChange (\(Self.updateCounter), Diff: \(diff))")
                if !diff.isEmpty {
                    self.syncItemHistory.append(SyncHistoryItem(id: self.syncItemHistory.count + 1, state: self.state, diff: diff))
                }
            }
            .store(in: &globalCancellables)
#endif

        state.$deleteCount
            .receive(on: DispatchQueue.main)
            // Transforms the value stream to old and new values that .sink can
            // then compare. The initial values for old and new are both set to 0.
            .scan((0, 0)) { (current, newValue) -> (oldValue: Int, newValue: Int) in
                return (current.newValue, newValue)
            }
            // First drop is the initial newValue being set.
            // Second drop is the initial oldValue being set.
            .dropFirst(2)
            .sink { [weak self] (oldValue, newValue) in
                guard let self else { return }

                // Show an alert each time `deleteCount` increases.
                if newValue > oldValue {
                    deleteAlerter.showAlert(for: state.accountInfo?.email)
                }
            }
            .store(in: &globalCancellables)

        guard let promoCampaignInteractor else { return }

        Publishers.CombineLatest3(
            promoCampaignInteractor.activeCampaign,
            state.$userInfo,
            state.$userSettings
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] campaign, userInfo, userSettings in
            guard let userInfo, let userSettings else {
                Log.trace("Promo campaign filtered out because user info or settings aren't available yet")
                self?.state.setVisibleCampaign(.none)
                return
            }

            // In-app notifications are defined as bit 15 of userSettings.news
            let userHasInAppNotificationsEnabled = ((userSettings.news >> 14) & 1) == 1 ? true : false

            // We don't display campaigns to users who are
            // * Paying customers
            // * Delinquent users
            // * Users who disabled in-app notifications
            if userInfo.isDelinquent || userInfo.isPaid || !userHasInAppNotificationsEnabled {
                Log.trace("Promo campaign filtered out because user is not in the target audience")
                self?.state.setVisibleCampaign(.none)
                return
            }

            self?.state.setVisibleCampaign(campaign)
        }
        .store(in: &userCancellables)
    }

// MARK: - Update availability (appUpdateService)

#if HAS_BUILTIN_UPDATER
    private func subscribeToUpdateAvailability() {
        Log.trace()
        didReceiveUpdateAvailability(
            availabilityStatus: appUpdateService?.updateAvailability ?? UpdateAvailabilityStatus.checking
        )
        appUpdateService?.updateAvailabilityPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [unowned self] in self.didReceiveUpdateAvailability(availabilityStatus: $0) })
            .store(in: &globalCancellables)
    }
    private func didReceiveUpdateAvailability(availabilityStatus: UpdateAvailabilityStatus) {
        if case .readyToInstall = availabilityStatus {
            self.state.setUpdateAvailable(true)
        } else {
            self.state.setUpdateAvailable(false)
        }
    }
#endif

// MARK: - Login (sessionVault.accountInfoPublisher)

    private func subscribetoLogin() {
        Log.trace()

        assert(sessionVault != nil)
        Task { @MainActor in
            didReceiveAccountInfo(accountInfo: sessionVault?.getAccountInfo())
        }
        sessionVault?.accountInfoPublisher
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [unowned self] in self.didReceiveAccountInfo(accountInfo: $0) })
            .store(in: &userCancellables)
    }
    private func didReceiveAccountInfo(accountInfo: AccountInfo?) {
        Log.trace()
        state.setAccountInfo(accountInfo)
    }

// MARK: - UserInfo (sessionVault.userInfoPublisher)

    private func subscribetoUserInfo() {
        Log.trace()

        assert(sessionVault != nil)
        Task { @MainActor in
            didReceiveUserInfo(userInfo: sessionVault?.getUserInfo())
        }
        sessionVault?.userInfoPublisher
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [unowned self] in self.didReceiveUserInfo(userInfo: $0) })
            .store(in: &userCancellables)
    }
    private func didReceiveUserInfo(userInfo: UserInfo?) {
        Log.trace()
        state.setUserInfo(userInfo)
    }

// MARK: - Logout (logoutStateService)

    private func subscribeToLogout() {
        Log.trace()

        assert(logoutStateService != nil)
        logoutStateService?.isLoggedInPublisher
            .removeDuplicates()
            .sink(receiveValue: { [unowned self] in self.didReceiveLogoutState(isSignedIn: $0) })
            .store(in: &globalCancellables)
    }
    private func didReceiveLogoutState(isSignedIn: Bool) {
        Log.trace()
        // update state only when not signed in
        guard !isSignedIn else { return }
        state.setAccountInfo(nil)
        state.setUserInfo(nil)
    }

// MARK: - File sync (syncObserver)
    private func subscribeToSyncChanges() {
        Log.trace()

        assert(syncObserver != nil)
        syncObserver?.startSyncMonitoring()
    }

// MARK: - Network state (networkStateService)

    private func subscribeToNetworkState() {
        Log.trace()

        assert(networkStateService != nil)
        networkStateService?.state
            .removeDuplicates()
            .sink(receiveValue: { [unowned self] in self.didReceiveNetworkState(networkState: $0) })
            .store(in: &globalCancellables)
    }
    
    private func didReceiveNetworkState(networkState: NetworkState) {
        Task { @MainActor in
            do {
                Log.trace()
                state.setOffline(networkState == .unreachable)
                try await syncObserver?.updateSyncState(paused: state.isPaused,
                                                        offline: state.isOffline,
                                                        fullResyncInProgress: state.fullResyncState.isHappening)
            } catch {
                Log.error("updateSyncState failed", error: error, domain: .application)
            }
        }
    }

// MARK: - ElapsedTimeService

    private func subscribeToPassageOfTime() async {
        Log.trace()

        await self.elapsedTimeService?.startTimer()
    }
}

// MARK: - Mocks

#if HAS_QA_FEATURES
extension ApplicationEventObserver {

#if HAS_BUILTIN_UPDATER
    public func mockUpdateAvailability(available: Bool) {
        if state.isUpdateAvailable {
            didReceiveUpdateAvailability(availabilityStatus: .checking)
        } else {
            didReceiveUpdateAvailability(availabilityStatus: .readyToInstall(version: "1.0.0"))
        }
    }
#endif

    public func mockOfflineStatus(offline: Bool) {
        didReceiveNetworkState(networkState: offline ? .unreachable : .reachable(.wifi))
    }

    public func mockAccountInfo(loggedIn: Bool) {
        didReceiveAccountInfo(accountInfo: loggedIn ? ApplicationState.mockAccountInfo : nil)
    }
    public func mockLogin() {
        state.setAccountInfo(ApplicationState.mockAccountInfo)
        state.setUserInfo(UserInfo(usedSpace: 100, maxSpace: 200, invoiceState: .onTime, isPaid: true))
    }
    public func mockLogout() {
        state.setAccountInfo(nil)
        state.setUserInfo(nil)
    }
    public func mockErrorState() {
        let erroredSyncItem = ReportableSyncItem(
            id: "id",
            modificationTime: Date.now,
            filename: "filename",
            location: "location",
            mimeType: "application/json",
            fileSize: 123,
            operation: .create,
            state: .errored,
            progress: 47,
            errorDescription: "Error description"
        )
        state.items.append(erroredSyncItem)

    }
}
#endif

#if HAS_QA_FEATURES
/// Displayed in QAStateDebuggingView
struct SyncHistoryItem: CustomStringConvertible, Equatable {
    var description: String {
        diff.map { $0.description }.joined(separator: "\n")
    }

    let id: Int
    let state: ApplicationState
    let diff: [ApplicationState.Property]
    let date = Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
}
#endif
