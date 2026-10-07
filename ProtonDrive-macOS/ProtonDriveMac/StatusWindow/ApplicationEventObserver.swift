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
import FileProvider
import PDFileProvider
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

@MainActor
class ApplicationEventObserver: ObservableObject {
#if HAS_QA_FEATURES
    @Published private(set) var state: ApplicationState
    @Published var syncItemHistory = [SyncHistoryItem]()
    @SettingsStorage(QASettingsConstants.driveMacPromoBannerDisabled) var hasPromoBannerDisabledInQASettings: Bool?

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

    /// Owns the domain's progress observation and presentation.
    private let globalProgressObserver: GlobalProgressObserver

    /// Fires whenever a user logs in, and passes an `AccountInfo` object
    private var sessionVault: SessionVault?

    /// Fires every `ElapsedTimeService.timeInterval` seconds, only the dropdown Menu or Status Window are opened.
    private var elapsedTimeService: ElapsedTimeService?

    /// Fires whenever there's a change to feature flags for the user
    private var featureFlagProvider: DriveFeatureFlagsProvider?

    /// Fires whenever there's a change to active promo campaigns for the user.
    private var promoCampaignInteractor: PromoCampaignInteractorProtocol?

    /// Responsible for fetching user config
    private var generalSettingsService: GeneralSettings?

    private let resyncUpdateSubject = PassthroughSubject<(Int, Int?), Never>()

    /// Always-on
    private var globalCancellables = Set<AnyCancellable>()
    /// Only while user is logged in
    private var userCancellables = Set<AnyCancellable>()

    init(
        state: ApplicationState,
        logoutStateService: LoggedInStateReporter?,
        networkStateService: NetworkStateInteractor?,
        appUpdateService: AppUpdateServiceProtocol?,
        promoCampaignInteractor: PromoCampaignInteractorProtocol?,
        progressSource: any GlobalProgressSource
    ) {
        self.state = state
        self.globalProgressObserver = GlobalProgressObserver(
            state: state,
            progressSource: progressSource
        )
        self.logoutStateService = logoutStateService
        self.networkStateService = networkStateService
        self.appUpdateService = appUpdateService
        self.promoCampaignInteractor = promoCampaignInteractor

        self.deleteAlerter = DeleteAlerter()

        #if HAS_QA_FEATURES
        self._hasPromoBannerDisabledInQASettings.configure(with: Constants.appGroup)
        #endif
    }

    deinit {
        Log.trace()
        // Cancel subscriptions here; live teardown also resets main-actor UI state.
        userCancellables.removeAll()
        globalCancellables.removeAll()
    }

    /// Starts the network/logout/update observations. Separate from `init` so the observer can be
    /// created without side effects until the app starts.
    func startObserving() {
        setUpObservers()
    }

    // MARK: - Public

    /// Some Drive services are only available after user is logged in,
    /// such as the session vault, general settings and feature flags.
    ///
    /// This function provides a convenient place to configure observation
    /// of these services. It's expected that any service with long running
    /// observations are cancelled in `stopMonitoring` as needed.
    public func configurePostLoginServices(
        syncObserver: SyncDBObserver,
        sessionVault: SessionVault?,
        settingsService: GeneralSettings?,
        featureFlagProvider: DriveFeatureFlagsProvider?
    ) {
        Log.trace()

        self.syncObserver = syncObserver
        self.elapsedTimeService = ElapsedTimeService(state: state)

        self.sessionVault = sessionVault

        syncObserver.startSyncMonitoring()
        elapsedTimeService?.startTimer()

        self.subscribetoLogin()
        self.subscribetoUserInfo()

        generalSettingsService = settingsService
        generalSettingsService?.fetchUserSettings()

        generalSettingsService?.userSettings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] userSettings in
                self?.state.setUserSettings(userSettings)
            }
            .store(in: &userCancellables)

        self.featureFlagProvider = featureFlagProvider
    }

    /// - Parameters:
    ///   - all: stop all subscriptions, not just user-specific ones.
    public func stopMonitoring(dueToSignOut: Bool) {
        Log.trace()

        self.syncObserver = nil
        stopObservingProgress()
        self.elapsedTimeService = nil
        self.sessionVault = nil
        self.generalSettingsService = nil
        self.featureFlagProvider = nil
        self.userCancellables.removeAll()

        didReceiveLogoutState(isSignedIn: false)

        if !dueToSignOut {
            self.globalCancellables.removeAll()
        }
    }

    func startObservingProgress(for domain: NSFileProviderDomain) {
        globalProgressObserver.startObservingProgress(for: domain)
    }

    func stopObservingProgress() {
        globalProgressObserver.stopObservingProgress()
    }

#if HAS_QA_FEATURES
    func toggleGlobalProgressQaStatusItemVisibility() {
        globalProgressObserver.toggleQaStatusItemVisibility()
    }
#endif

    public func pauseSyncing() async throws {
        Log.trace()

        assert(syncObserver != nil)

        try await syncObserver?.updateSyncState(paused: true,
                                                offline: state.isOffline,
                                                fullResync: state.fullResyncState.syncStateModifications)
        state.isPaused = true
    }

    public func resumeSyncing() async throws {
        Log.trace()
        
        assert(syncObserver != nil)

        try await syncObserver?.updateSyncState(paused: false,
                                                offline: state.isOffline,
                                                fullResync: state.fullResyncState.syncStateModifications)
        state.isPaused = false

        // When the user resumes syncing after a pause, the application state immediately switches
        // to "Synced", when in reality there may be unsynced changes, which the file provider is
        // in the process of figuring out.
        // Therefore, we set a "Looking for files to sync..." status for up to 15 seconds - after that,
        // either syncing has resumed and overwritten this status, or we change back to "Synced".
        state.isResuming = true
        defer { state.isResuming = false }
        try await Task.sleep(for: .seconds(15))
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

    public func togglePausedStatus() async throws {
        Log.trace()

        if case .paused = state.overallStatus {
            try await resumeSyncing()
        } else {
            try await pauseSyncing()
        }
    }

    public func cleanUpErrors() async {
        Log.trace()
        await syncObserver?.cleanUpErrors()
    }

    public func refreshItems() async throws {
        Log.trace()
        try await syncObserver?.fetchItems()
    }

    public func fullResyncStarted(isAutomatic: Bool) async throws {
        try await syncObserver?.updateSyncState(
            paused: state.isPaused,
            offline: state.isOffline,
            fullResync: (shouldDisconnectDomain: true, shouldPauseEvents: true)
        )
        state.resyncIsAutomatic = isAutomatic
        // Resume and retry re-enter this hook for the same run, so a dismissal there must stick.
        if !state.fullResyncState.isHappening {
            state.automaticResyncReasonDismissed = false
        }
        // Prep phase: no Pause/Cancel yet. fullResyncScanStarted(variant:) promotes this to .inProgress once
        // the service can actually honor them.
        state.fullResyncState = .starting
    }

    public func fullResyncScanStarted(variant: ApplicationState.FullResyncVariant) {
        // The service is now cancellable; allow Pause/Cancel. Guard so a late signal can't revive a resync
        // that already moved past .starting. Sync state is unchanged since .starting already froze the domain.
        guard case .starting = state.fullResyncState else { return }
        // Set the variant before .inProgress so the step list is picked from the first render.
        state.setFullResyncVariant(variant)
        state.fullResyncState = .inProgress(saved: 0, total: nil)
    }

    /// Advances `state.furthestResyncStep` to the index of `kind` within the current variant's step list,
    /// so the step-list UI can mark where a terminal resync stopped. Monotonic (see the state method).
    private func advanceFurthestResyncStep(to kind: FullResyncStepKind) {
        guard let index = FullResyncStepList.kinds(for: state.fullResyncVariant).firstIndex(of: kind) else { return }
        state.advanceFurthestResyncStep(to: index)
    }

    public func fullResyncItemCountUpdated(saved: Int, total: Int?) {
        Log.trace()
        resyncUpdateSubject.send((saved, total))
        // Downloading begins only once at least one item is actually saved (saved > 0) — not at the mere
        // discovery→download boundary (saved == 0), so a failure there stays attributed to discovery. Publish
        // this one transition immediately (bypassing the throttle) together with the marker advance, so the
        // marker never leads the rendered step: an error arriving in the throttle window would otherwise mark
        // Downloading as failed while the UI still showed Discovering. Later progress stays throttled, and the
        // monotonic marker won't move again.
        guard state.fullResyncVariant == .v2, total != nil, saved > 0,
              case .inProgress = state.fullResyncState,
              let downloadingIndex = FullResyncStepList.kinds(for: state.fullResyncVariant).firstIndex(of: .downloading),
              state.furthestResyncStep < downloadingIndex else { return }
        state.fullResyncState = .inProgress(saved: saved, total: total)
        advanceFurthestResyncStep(to: .downloading)
    }

    private func throttledFullResyncItemCountUpdated(_ saved: Int, _ total: Int?) {
        Log.trace()
        // Drop throttled counts that land after downloading ends, so a stale one can't resurrect the UI.
        guard case .inProgress = state.fullResyncState else { return }
        state.fullResyncState = .inProgress(saved: saved, total: total)
    }
    
    public func fullResyncReenumerationStarted() async throws {
        // The domain must be reconnected so the file provider can enumerate the changes
        // applied during the recovery — do not reapply a prior user pause here.
        state.isPaused = false
        try await syncObserver?.updateSyncState(
            paused: false,
            offline: state.isOffline,
            fullResync: (shouldDisconnectDomain: false, shouldPauseEvents: true)
        )
        state.fullResyncState = .enumerating(.waitingForTheWorkingSetEnumerationToFinish(seconds: 0, enumerated: 0, total: nil))
        // Enumeration has begun: the resync has reached the "Applying updates" phase.
        advanceFurthestResyncStep(to: .applyingUpdates)
    }
    
    func fullResyncReenumerationProgresses(enumerationState: ApplicationState.FullResyncState.EnumeratingState) {
        // Only advance while still enumerating; a terminal transition (e.g. .idle from cancel) raised
        // concurrently with the poll loop must not be clobbered back to .enumerating by a late tick.
        guard case .enumerating = state.fullResyncState else { return }
        state.fullResyncState = .enumerating(enumerationState)
        // The fetch-item pass means the resync has reached "Refreshing item details".
        if case .fetchItemPassInProgress = enumerationState {
            advanceFurthestResyncStep(to: .refreshingDetails)
        }
    }
    
    public func fullResyncCompleted(hasFileProviderResponded: Bool, warning: String?) {
        state.fullResyncState = .completed(hasFileProviderResponded: hasFileProviderResponded, warning: warning)
    }
    
    public func fullResyncFinished()  {
        state.fullResyncState = .idle
        state.resyncIsAutomatic = false
    }
    
    public func fullResyncErrored(message: String) {
        state.fullResyncState = .errored(message)
    }

    public func fullResyncCancelled() async throws {
        state.fullResyncState = .idle
        state.resyncIsAutomatic = false
        try await syncObserver?.updateSyncState(
            paused: state.isPaused,
            offline: state.isOffline,
            fullResync: (shouldDisconnectDomain: false, shouldPauseEvents: false)
        )
    }

    public func fullResyncPaused(count: Int) async throws {
        // Pause freezes the app like an in-progress scan: domain disconnected, events paused, file
        // operations deferred. The recovery DB is kept so Resume can continue it.
        state.fullResyncState = .paused(count)
        try await syncObserver?.updateSyncState(
            paused: state.isPaused,
            offline: state.isOffline,
            fullResync: (shouldDisconnectDomain: true, shouldPauseEvents: true)
        )
    }

    @MainActor
    public func fullResyncPauseRequested() {
        // Optimistic: reflect the pause the instant the user taps it, before the engine winds down (it
        // finishes its in-flight metadata request first, which can take seconds). Once .paused, the
        // progress writers drop the winding-down updates so the percentage stops climbing. The engine's
        // own fullResyncPaused does the authoritative pause (events/domain) when it settles.
        guard case .inProgress(let saved, _) = state.fullResyncState else { return }
        state.fullResyncState = .paused(saved)
    }

    @MainActor
    public func fullResyncResumeRequested() {
        // Optimistic resume while the paused engine is still winding down: show the preparing screen now
        // (as a normal resume does) so Resume feels responsive. The coordinator restarts the scan once
        // the engine settles.
        guard case .paused = state.fullResyncState else { return }
        state.fullResyncState = .starting
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
                self?.throttledFullResyncItemCountUpdated($0.0, $0.1)
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

                if !diff.isEmpty {
                    Log.uiEvent(diff.map { $0.description })
                }
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

                guard !RuntimeConfiguration.shared.enableTestAutomation else { return }

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
            guard let self, let featureFlagProvider else {
                return
            }

            guard !featureFlagProvider.isEnabled(flag: .driveMacPromoBannerDisabled) else {
                Log.trace("Promo campaign filtered out because killswitch is active")
                return self.state.setVisibleCampaign(nil)
            }

            #if HAS_QA_FEATURES
            if hasPromoBannerDisabledInQASettings == true {
                Log.trace("Promo campaign filtered out because it's disabled in QA settings")
                return self.state.setVisibleCampaign(nil)
            }
            #endif

            guard let userInfo, let userSettings else {
                Log.trace("Promo campaign filtered out because user info or settings aren't available yet")
                self.state.setVisibleCampaign(.none)
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
                self.state.setVisibleCampaign(.none)
                return
            }

            self.state.setVisibleCampaign(campaign)
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
            .receive(on: DispatchQueue.main)
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

// MARK: - Network state (networkStateService)

    private func subscribeToNetworkState() {
        Log.trace()

        assert(networkStateService != nil)
        networkStateService?.state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
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
                                                        fullResync: state.fullResyncState.syncStateModifications)
            } catch {
                Log.error("updateSyncState failed", error: error, domain: .application)
            }
        }
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
