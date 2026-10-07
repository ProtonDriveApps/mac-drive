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
import PDCore
import AppKit
import SwiftUI
import PDLocalization
import ProtonCoreUIFoundations

/// Encapsulates the state of the entire app, driving the UI by publishing updates.
class ApplicationState: ObservableObject {
    /// State of the NotificationView (cases are listed in order of priority)
    enum NotificationState: CustomStringConvertible, Equatable {
        case error(Int)
        case update
        case volumeLocked
        case resyncFinished
        /// Why an app-initiated resync is running. Dismissible.
        case automaticResyncReason
        case none

        var description: String {
            switch self {
            case .error(let count): "Errors (\(count)"
            case .update: "Update"
            case .volumeLocked: "Volume locked"
            case .resyncFinished: "Resync finished"
            case .automaticResyncReason: "Automatic resync reason"
            case .none: "None"
            }
        }
    }

    /// Which scan engine drives the current resync. Picks the step list (v1: 3 steps, v2: 4) and
    /// disambiguates the indeterminate `.inProgress(_, nil)` phase (v1 download vs v2 discovery).
    enum FullResyncVariant: Equatable {
        case v1, v2
        
        init(scanEngineVersion: ScanEngineVersion) {
            switch scanEngineVersion {
            case .v1: self = .v1
            case .v2: self = .v2
            }
        }
    }

    enum FullResyncState: CustomStringConvertible, Equatable {

        enum EnumeratingState: Equatable {
            case waitingForTheWorkingSetEnumerationToFinish(seconds: Double, enumerated: Int, total: Int?)
            case waitingForTheFetchItemPass(seconds: Double)
            case fetchItemPassInProgress(seconds: Double, fetched: Int, expected: Int)
        }
        
        case idle
        // Prep phase before the scan is cancellable. Looks in-progress but offers no Pause/Cancel yet
        // (see isCancellable).
        case starting
        case inProgress(saved: Int, total: Int?)
        case enumerating(EnumeratingState)
        case completed(hasFileProviderResponded: Bool?, warning: String?)
        case errored(String)
        case paused(Int)

        var syncStateModifications: (shouldDisconnectDomain: Bool, shouldPauseEvents: Bool) {
            switch self {
            case .idle, .completed: (false, false)
            // Paused freezes like an in-progress scan: domain disconnected, events paused, operations deferred.
            case .starting, .inProgress, .errored, .paused: (true, true)
            case .enumerating: (false, true)
            }
        }

        var isHappening: Bool {
            switch self {
            case .idle, .completed: false
            case .starting, .inProgress, .enumerating, .errored, .paused: true
            }
        }

        /// Cancellable only during the download/refresh phase — not while `.starting` (too early) or once
        /// enumerating (DBs already swapped).
        var isCancellable: Bool {
            if case .inProgress = self { return true }
            return false
        }

        /// The case identity, without the associated values. Lets callers compare "still the same phase?"
        /// across value changes (an `.inProgress` progress tick keeps the same phase), which `Equatable` on
        /// the state itself cannot express. Adding a case to `FullResyncState` fails to compile here until
        /// it is mapped, so the discriminant can't silently drift from the state.
        enum Phase: String, Equatable {
            case idle, starting, inProgress, enumerating, completed, errored, paused
        }

        var phase: Phase {
            switch self {
            case .idle: .idle
            case .starting: .starting
            case .inProgress: .inProgress
            case .enumerating: .enumerating
            case .completed: .completed
            case .errored: .errored
            case .paused: .paused
            }
        }

        /// Stable machine-readable case name for the TestRunner (distinct from the localized `description`).
        /// Derived from `phase`, but comparisons must use `phase` — this is display/diagnostics output.
        var statusName: String { phase.rawValue }

        /// User-initiated wording. The UI goes through `description(isAutomatic:)`; this serves the QA
        /// diagnostics dump and the didSet trace.
        var description: String {
            description(isAutomatic: false)
        }

        /// - Parameter isAutomatic: app-initiated; names the refresh instead of the step labels.
        func description(isAutomatic: Bool) -> String {
            switch self {
            case .idle:
                "Idle"
            case .starting:
                // Nothing downloaded yet, so no step number.
                isAutomatic ? Localization.full_resync_auto_title : "Resync in progress: preparing…"
            case .inProgress:
                isAutomatic
                    ? Localization.full_resync_auto_status_downloading
                    : "Resync step 1/2: downloading file information..."
            case .enumerating(let state):
                (isAutomatic
                    ? Localization.full_resync_auto_status_applying
                    : "Resync step 2/2: applying updates") + Self.enumeratingQADetail(for: state)
            case .completed(let hasFileProviderResponded, let warning):
                if let warning {
                    "Full resync completed with issues: \(warning)"
                } else if isAutomatic {
                    Localization.full_resync_auto_completed + Self.completedQADetail(hasFileProviderResponded: hasFileProviderResponded)
                } else {
                    "Full resync completed" + Self.completedQADetail(hasFileProviderResponded: hasFileProviderResponded)
                }
            case .errored(let message):
                "Full resync error: \(message)"
            case .paused(let count):
                isAutomatic
                    ? Localization.full_resync_auto_status_paused(itemsProcessed: count)
                    : "Full resync paused — \(count) files so far"
            }
        }

        /// QA-only detail appended to the completed label when the file provider never confirmed.
        private static func completedQADetail(hasFileProviderResponded: Bool?) -> String {
#if HAS_QA_FEATURES
            hasFileProviderResponded == false ? " (File provider has not responded)" : ""
#else
            ""
#endif
        }

        /// QA-only detail appended to the step-2 label: distinguishes enumeration from the item-fetch pass and shows the counter.
        private static func enumeratingQADetail(for state: EnumeratingState) -> String {
#if HAS_QA_FEATURES
            switch state {
            case .waitingForTheWorkingSetEnumerationToFinish(let seconds, let enumerated, let total):
                return " (enumeration \(enumerated)/\(total.map { "\($0)" } ?? "?"), \(seconds)s)"
            case .waitingForTheFetchItemPass(let seconds):
                return " (waiting for item fetch, \(seconds)s)"
            case .fetchItemPassInProgress(let seconds, let fetched, let expected):
                return " (item fetch \(fetched)/\(expected), \(seconds)s)"
            }
#else
            _ = state // Silences the unused-parameter warning when the QA detail is compiled out.
            return ""
#endif
        }
    }

#if DEBUG
    /// How many times has this been instantiated.
    private static var counter = 0
#endif

    init() {
#if DEBUG
        Self.counter += 1

        // Make sure this is only instantiated once only if we're not running tests
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            assert(Self.counter == 1)
        }
#endif

        $items
            .throttle(for: .seconds(throttlingInterval), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] value in
                self?.throttledItems = value
            }
            .store(in: &cancellables)
    }

    // MARK: General state

    @Published private(set) var accountInfo: AccountInfo?
    @Published private(set) var userInfo: UserInfo?
    @Published private(set) var userSettings: UserSettings?
    @Published private(set) var canGetMoreStorage = true
    @Published private(set) var isOffline = false
    @Published private(set) var isUpdateAvailable = false
    @Published private(set) var isVolumeLocked = false
    /// Percentage of launch sequence that has been completed
    @Published private(set) var launchCompletion = 0
    @Published private(set) var visibleCampaign: PromoCampaignConfiguration?

    // MARK: Sync state

    /// Updated whenever anything changes
    @Published var items: [ReportableSyncItem] = []
    var erroredItems: [ReportableSyncItem] {
        items.filter { $0.state == .errored }
    }

    /// How often should the list of items be refreshed
    private let throttlingInterval: TimeInterval = 1

    /// Updated whenever `items` change, but no more often than once every `throttlingInterval`.
    @Published private(set) var throttledItems: [ReportableSyncItem] = []

    private var cancellables = Set<AnyCancellable>()

    @Published var isSyncing = false
    @Published var isEnumerating = false
    @Published var isPaused = false
    @Published var isResuming = false
    @Published var fullResyncState: FullResyncState = .idle {
        didSet {
            Log.trace("Resync did set fullResyncState to \(fullResyncState)")
            // Reset the resync-scoped signals once the resync leaves an active phase.
            switch fullResyncState {
            case .idle, .completed:
                fullResyncVariant = .v1
                furthestResyncStep = 0
                resyncStepDetails = [:]
            case .starting:
                // A fresh attempt (including retry/resume after an error or pause) restarts at the first step.
                furthestResyncStep = 0
                resyncStepDetails = [:]
            default:
                break
            }
            // Retain the active step's latest detail, so a finished step keeps showing its final progress.
            if let active = FullResyncStepList.activeStep(variant: fullResyncVariant, state: fullResyncState) {
                resyncStepDetails[active.kind] = active.detail
                // Once downloading is active, discovery is complete and found `total` items. Keep the
                // "Discovering files" tally in sync with that total (never shrinking) so a resume — which
                // doesn't re-emit discovery progress — shows the real found count instead of a stale 0.
                if active.kind == .downloading, case let .determinate(_, total) = active.detail {
                    let previousFound: Int
                    if case let .indeterminate(count)? = resyncStepDetails[.discovering] {
                        previousFound = count
                    } else {
                        previousFound = 0
                    }
                    resyncStepDetails[.discovering] = .indeterminate(count: max(previousFound, total))
                }
            }
        }
    }

    /// True while the current resync was app-initiated. Survives `.completed`, which still describes it.
    @Published var resyncIsAutomatic = false

    /// In-memory on purpose: a relaunch restarts the resync, so the reason is restated once per session.
    @Published var automaticResyncReasonDismissed = false

    /// Scan engine of the current resync; set at scan start, reset when the resync ends.
    @Published private(set) var fullResyncVariant: FullResyncVariant = .v1

    /// Index (into the current variant's step list) of the furthest phase the resync has reached. The
    /// step-list UI reads it to mark where a terminal (errored/paused) resync stopped. Monotonic while a
    /// resync runs; reset when it ends.
    @Published private(set) var furthestResyncStep: Int = 0

    /// Each resync phase's last-seen inline detail, so a finished phase keeps showing its final progress
    /// (grayed) in the step list. Updated as the active phase advances; reset when the resync ends.
    @Published private(set) var resyncStepDetails: [FullResyncStepKind: FullResyncStep.StepDetail] = [:]

    @Published var lastSyncTime: TimeInterval?
    @Published var formattedTimeSinceLastSync: String = ApplicationSyncStatus.synced.displayLabel

    @Published var totalFilesLeftToSync: Int = 0
    @Published var errorCount: Int = 0

    /// Contains information about an enumeration in progress
    /// Written wherever you see `ItemEnumerationObserver.enumerationSyncItemIdentifier`
    /// Read in `SyncStorageManager.itemEnumerationProgress`
    @Published var itemEnumerationProgress: String?

    @Published var deleteCount = 0

    @Published var globalSyncStateDescription: String?
    
    // MARK: Computed

    var overallStatus: ApplicationSyncStatus {
        if launchCompletion < 100 {
            return .launching
        }
        if isVolumeLocked, accountInfo != nil {
            // Nothing can sync against a locked volume: outranks resync, pause, offline, and errors.
            return .volumeLocked
        }
        if fullResyncState.isHappening {
            return .fullResyncInProgress
        }
        if accountInfo == nil {
            if isUpdateAvailable {
                return .signedOutAndUpdateAvailable
            } else {
                return .signedOut
            }
        }
        if isPaused {
            return .paused
        }
        if isOffline {
            return .offline
        }
        if isSyncing && !fullResyncState.isHappening {
            return .syncing
        }
        if totalFilesLeftToSync > 0 {
            // Sometimes isSyncing is false because there are no files syncing at that moment, but there are still files left to sync -
            // so we return .syncing to avoid intermittent flashes of "Synced just now" in the middle of syncing.
            return .syncing
        }
        if isEnumerating || (isResuming && !isSyncing) {
            return .enumerating(itemEnumerationProgress)
        }
        if isUpdateAvailable {
            return .updateAvailable
        }
        if errorCount > 0 {
            return .errored(errorCount)
        }
        return .synced
    }

    func displayName(for status: ApplicationSyncStatus) -> String {
        switch status {
        case .synced:
            return formattedTimeSinceLastSync
        case .syncing where globalSyncStateDescription?.isEmpty == false:
            return globalSyncStateDescription ?? self.overallStatus.displayLabel
        case .fullResyncInProgress, .fullResyncCompleted:
            return fullResyncState.description(isAutomatic: resyncIsAutomatic)
        default:
            return status.displayLabel
        }
    }

    var notificationState: NotificationState {
        if isVolumeLocked {
            return .volumeLocked
        }
        if case .completed = fullResyncState {
            return .resyncFinished
        }
        if fullResyncState.isHappening {
            // An app-initiated resync explains itself until dismissed; error/update stay suppressed.
            guard resyncIsAutomatic, !automaticResyncReasonDismissed else { return .none }
            switch fullResyncState {
            case .starting, .inProgress, .paused:
                return .automaticResyncReason
            case .enumerating, .errored, .idle, .completed:
                // Enumeration reconnects the domain; the error view carries its own copy.
                return .none
            }
        }

        if isUpdateAvailable {
            return .update
        } else {
            if errorCount > 0 {
                return .error(errorCount)
            } else {
                return .none
            }
        }
    }

    var isLoggedIn: Bool {
        accountInfo != nil
    }

    var isLaunching: Bool {
        launchCompletion < 100
    }

    // MARK: - Setters

    func setLaunchCompletion(_ percentage: Int) {
        self.launchCompletion = percentage
    }

    func setFullResyncVariant(_ variant: FullResyncVariant) {
        self.fullResyncVariant = variant
    }

    /// Advances the furthest-reached resync step. Monotonic: never rewinds, so a late or out-of-order
    /// phase signal can't move the marker backwards.
    func advanceFurthestResyncStep(to index: Int) {
        self.furthestResyncStep = max(self.furthestResyncStep, index)
    }

    func setAccountInfo(_ accountInfo: AccountInfo?) {
        self.accountInfo = accountInfo
    }

    func setUserInfo(_ userInfo: UserInfo?) {
        self.userInfo = userInfo
    }

    func setOffline(_ isOffline: Bool) {
        self.isOffline = isOffline
    }

    func setUpdateAvailable(_ isUpdateAvailable: Bool) {
        self.isUpdateAvailable = isUpdateAvailable
    }

    func setVolumeLocked(_ isVolumeLocked: Bool) {
        self.isVolumeLocked = isVolumeLocked
    }

    func setCanGetMoreStorage(_ canGetMoreStorage: Bool) {
        Task { @MainActor in
            self.canGetMoreStorage = canGetMoreStorage
        }
    }

    func setUserSettings(_ settings: UserSettings?) {
        self.userSettings = settings
    }

    func setVisibleCampaign(_ campaign: PromoCampaignConfiguration?) {
        self.visibleCampaign = campaign
    }

    deinit {
        Log.trace()
    }
}

// MARK: - Extensions

extension ApplicationState: CustomDebugStringConvertible {
    struct Property: Equatable, Hashable, Encodable, CustomStringConvertible {
        let name: String
        let value: String
        init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
        var description: String {
            "\(name): \(value)"
        }
    }
    var properties: [Property] {
        return [
            Property("overallStatus", self.overallStatus.displayLabel),
            Property("overallStatusLabel", self.displayName(for: self.overallStatus)),
            Property("launchCompletion", self.launchCompletion.description),
            Property("accountInfo", self.accountInfo?.displayName ?? "logged out"),
            Property("isLoggedIn", self.isLoggedIn.description),
            Property("lastSyncTime", self.lastSyncTime?.description ?? "n/a"),
            Property("timeSinceSync", self.formattedTimeSinceLastSync),
            Property("itemCount", self.items.count.description),
            Property("totalFilesLeftToSync", self.totalFilesLeftToSync.description),
            Property("errorCount", self.errorCount.description),
            Property("isSyncing", self.isSyncing.description),
            Property("isPaused", self.isPaused.description),
            Property("isResuming", self.isResuming.description),
            Property("isOffline", self.isOffline.description),
            Property("isEnumerating", self.isEnumerating.description),
            Property("itemEnumerationProgress", itemEnumerationProgress ?? "n/a"),
            Property("isUpdateAvailable", self.isUpdateAvailable.description),
            Property("isVolumeLocked", self.isVolumeLocked.description),
            Property("notificationState", notificationState.description),
            Property("userInfo.usedSpace", userInfo?.usedSpace.description ?? "n/a"),
            Property("userInfo.maxSpace", userInfo?.maxSpace.description ?? "n/a"),
            Property("canGetMoreStorage", canGetMoreStorage.description),
            Property("fullResyncState", fullResyncState.statusName),
            Property("fullResyncState.description", fullResyncState.description(isAutomatic: resyncIsAutomatic)),
            Property("deleteCount", deleteCount.description),
            Property("globalSyncStateDescription", globalSyncStateDescription ?? self.overallStatus.displayLabel),
        ]
    }

    func diff(against otherState: ApplicationState) -> [Property] {
        return Array(Set(self.properties).symmetricDifference(Set(otherState.properties)))
    }

    var debugDescription: String {
        if let jsonData = try? JSONSerialization.data(
            withJSONObject: properties.map { "\($0.name): \($0.value)"
            },
            options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }

        return "{}" // Return an empty JSON object if serialization fails
    }
}

extension ApplicationState: Equatable {
    static func == (lhs: ApplicationState, rhs: ApplicationState) -> Bool {
        lhs.properties == rhs.properties
    }
}

// MARK: - Mocks

#if HAS_QA_FEATURES
extension ApplicationState {
    static var mockAccountInfo: AccountInfo {
        AccountInfo(
            userIdentifier: "",
            email: "username@example.com",
            displayName: "Alice Smith",
            accountRecovery: nil
        )
    }

    static func mock(
        loggedIn: Bool = true,
        isSyncing: Bool = false,
        isPaused: Bool = false,
        isUpdateAvailable: Bool = false,
        isVolumeLocked: Bool = false,
        isOffline: Bool = false,
        isLaunching: Bool = false,
        secondsAgo: Int = 0,
        canGetMoreStorage: Bool = true,
        totalFilesLeftToSync: Int? = nil,
        items: [ReportableSyncItem] = [],
        errorCount: Int = 0
    ) -> ApplicationState {
        let state = ApplicationState()
        if loggedIn {
            state.accountInfo = mockAccountInfo
        }
        state.isSyncing = isSyncing
        state.isPaused = isPaused
        state.isUpdateAvailable = isUpdateAvailable
        state.isVolumeLocked = isVolumeLocked
        state.isOffline = isOffline
        state.launchCompletion = isLaunching ? 50 : 100

        if secondsAgo > 0 {
            state.formattedTimeSinceLastSync = "Synced \(secondsAgo)s ago"
        }
        state.canGetMoreStorage = canGetMoreStorage

        state.items = items
        state.errorCount = items.filter { if case .errored = $0.state { true } else { false } }.count
        if let totalFilesLeftToSync, totalFilesLeftToSync > items.count {
            state.totalFilesLeftToSync = totalFilesLeftToSync
        } else {
            state.totalFilesLeftToSync = items.count
        }

        return state
    }

    static var mockWithErrorItems: ApplicationState {
        let mock = mock()
        mock.items = mockItems
        return mock
    }

    static var mockItems: [ReportableSyncItem] {
        [
            ReportableSyncItem(
                id: "id1",
                modificationTime: Date(),
                filename: "IMG_0042-19.jpg",
                location: "Test/IMG_0042-19.jpg",
                mimeType: "image/jpeg",
                fileSize: 1048632,
                operation: .create,
                state: .inProgress,
                progress: 70,
                errorDescription: nil
            ),
            ReportableSyncItem(
                id: "id2",
                modificationTime: Date(),
                filename: "Folder A",
                location: "Test/Folder A",
                mimeType: nil,
                fileSize: nil,
                operation: .create,
                state: .finished,
                progress: 100,
                errorDescription: nil
            ),
            ReportableSyncItem(
                id: "id3",
                modificationTime: Date(),
                filename: "Document.pdf",
                location: "Folder B/Document.pdf",
                mimeType: "application/pdf",
                fileSize: 116921,
                operation: .update,
                state: .errored,
                progress: 0,
                errorDescription: "Could not modify error reason"
            )
        ]
    }

    static var mockErroredState = FileProviderOperation.allCases.map { operation in
        SyncItemState.allCases.map { syncState in
            ReportableSyncItem(
                id: UUID().uuidString,
                modificationTime: Date(),
                filename: "IMG_0042-19.jpg",
                location: "/path/to/file",
                mimeType: "image/jpeg",
                fileSize: 1339346742,
                operation: operation,
                state: syncState,
                progress: 73,
                errorDescription: "An error's localized description (\(syncState), \(operation))"
            )
        }
    }.reduce([], +)
}
#endif
