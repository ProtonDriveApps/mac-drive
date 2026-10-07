// Copyright (c) 2025 Proton AG
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

import Foundation
import PDCore
import PDFileProvider
import PDLocalization

private struct FullResyncWaitTimedOut: LocalizedError {
    let operation: String
    let seconds: Double
    var errorDescription: String? {
        "Full resync wait timed out after \(seconds)s waiting on: \(operation)"
    }
}

protocol FullResyncApplicationStateObserverProtocol  {
    /// - Parameter isAutomatic: true when the app started the resync itself (a backend refresh event),
    ///   so the UI can explain why it is happening.
    @MainActor func fullResyncStarted(isAutomatic: Bool) async throws
    @MainActor func fullResyncScanStarted(variant: ApplicationState.FullResyncVariant)
    @MainActor func fullResyncItemCountUpdated(saved: Int, total: Int?)
    @MainActor func fullResyncReenumerationStarted() async throws
    @MainActor func fullResyncReenumerationProgresses(enumerationState: ApplicationState.FullResyncState.EnumeratingState)
    @MainActor func fullResyncCompleted(hasFileProviderResponded: Bool, warning: String?)
    @MainActor func fullResyncFinished()
    @MainActor func fullResyncErrored(message: String)
    @MainActor func fullResyncCancelled() async throws
    @MainActor func fullResyncPaused(count: Int) async throws
    @MainActor func fullResyncPauseRequested()
    @MainActor func fullResyncResumeRequested()

    @MainActor var state: ApplicationState { get }
    @MainActor func waitUntilEnumerationHasBegunAndEnded() async throws
}

extension ApplicationEventObserver: FullResyncApplicationStateObserverProtocol {}

enum ResyncTrigger: Equatable {
    case userStarted
    case userContinued
    case loginReconnectionStarted
    case loginReconnectionResumed
    case refreshEventStarted
    case refreshEventContinued

    /// Both login-reconnection phases keep the domain disconnected until the rebuild completes, so the
    /// resync is neither pausable nor cancellable-to-idle.
    var isLoginReconnection: Bool {
        switch self {
        case .loginReconnectionStarted, .loginReconnectionResumed: true
        case .userStarted, .userContinued, .refreshEventStarted, .refreshEventContinued: false
        }
    }

    /// Backend-triggered: pausable, but not cancellable while running or paused.
    var isRefreshEvent: Bool {
        switch self {
        case .refreshEventStarted, .refreshEventContinued: true
        case .userStarted, .userContinued, .loginReconnectionStarted, .loginReconnectionResumed: false
        }
    }

    /// Continues a preserved recovery DB instead of starting clean.
    var isResume: Bool {
        switch self {
        case .userContinued, .loginReconnectionResumed, .refreshEventContinued: true
        case .userStarted, .loginReconnectionStarted, .refreshEventStarted: false
        }
    }

    /// Trigger a resume/retry must use to keep the same controls.
    var continuation: ResyncTrigger {
        switch self {
        case .loginReconnectionStarted, .loginReconnectionResumed: .loginReconnectionResumed
        case .refreshEventStarted, .refreshEventContinued: .refreshEventContinued
        case .userStarted, .userContinued: .userContinued
        }
    }
}

protocol FullResyncCoordinating: AnyObject {
    /// The trigger behind the current (or most recent) resync. The recovery UI checks
    /// `resyncTrigger.isLoginReconnection` to hide the no-op Cancel button: there the domain is
    /// disconnected, so cancelling cannot return to a working state — only Retry or "Create new sync
    /// folder" are meaningful.
    var resyncTrigger: ResyncTrigger { get }
    @MainActor
    func performFullResync(onlyIfPreviouslyInterrupted: Bool,
                           trigger: ResyncTrigger,
                           onReenumerationWillBegin: (@MainActor () async throws -> Void)?,
                           onTerminalFailure: (@MainActor () -> Void)?)
    func finishFullResync()
    @MainActor
    func retryFullResync()
    func cancelFullResync()
    func pauseFullResync()
    @MainActor
    func resumeFullResync()
    func cancelPausedResync()
}

extension FullResyncCoordinating {
    @MainActor
    func performFullResync(onlyIfPreviouslyInterrupted: Bool = false) {
        performFullResync(onlyIfPreviouslyInterrupted: onlyIfPreviouslyInterrupted,
                          trigger: .userStarted,
                          onReenumerationWillBegin: nil,
                          onTerminalFailure: nil)
    }

    @MainActor
    func performFullResync(trigger: ResyncTrigger,
                           onReenumerationWillBegin: (@MainActor () async throws -> Void)? = nil,
                           onTerminalFailure: (@MainActor () -> Void)? = nil) {
        performFullResync(onlyIfPreviouslyInterrupted: false,
                          trigger: trigger,
                          onReenumerationWillBegin: onReenumerationWillBegin,
                          onTerminalFailure: onTerminalFailure)
    }
}

/// Coordinates the flow of information between all the moving parts involved in a Resync: about a Resync between the domain, menu bar, and application state.
final class FullResyncCoordinator: FullResyncCoordinating {

    @RawRepresentableSettingsStorage(UserDefaults.FileProvider.shouldReenumerateItemsKey.rawValue, defaultValue: ChangesEnumerationMode.eventLoop) var shouldReenumerateItems: ChangesEnumerationMode
    @SettingsStorage(UserDefaults.FileProvider.workingSetEnumerationInProgressKey.rawValue) var workingSetEnumerationInProgress: Bool?
    @SettingsStorage(UserDefaults.FileProvider.fullResyncInProgressKey.rawValue) var fullResyncInProgress: Bool?
    @SettingsStorage(UserDefaults.FileProvider.cannotSynchronizeEarlyExitOccurredKey.rawValue) var cannotSynchronizeEarlyExitOccurred: Bool?
    @SettingsStorage(UserDefaults.FileProvider.cannotSynchronizeEarlyExitCountKey.rawValue) var cannotSynchronizeEarlyExitCount: Int?
    @SettingsStorage(UserDefaults.FileProvider.fetchedItemCountKey.rawValue) var fetchedItemCount: Int?
    @SettingsStorage(UserDefaults.FileProvider.resyncEnumerationPageCountKey.rawValue) var resyncEnumerationPageCount: Int?
    /// Set while a refresh-triggered rebuild is owed. Not reset in `init`: it must survive a relaunch.
    @SettingsStorage(UserDefaults.FileProvider.refreshEventResyncPendingKey.rawValue) var refreshEventResyncPending: Bool?
    @SettingsStorage(UserDefaults.FileProvider.resyncEnumeratedItemCountKey.rawValue) var resyncEnumeratedItemCount: Int?
    @SettingsStorage(UserDefaults.FileProvider.resyncEnumeratedItemTotalKey.rawValue) var resyncEnumeratedItemTotal: Int?

    private let applicationEventObserver: FullResyncApplicationStateObserverProtocol
    private let fullResyncService: FullResyncServiceProtocol
    private let domainOperationsService: DomainOperationsServiceProtocol
    private let observationCenter: UserDefaultsObservationCenter
    private let menuBarCoordinator: MenuBarCoordinator?
    private let fullResyncMetricsReporter: FullResyncMetricsReporting
    private let dateResource: DateResource

    /// Directory for the node-id snapshot temp files (the app-group container in production).
    private let settingsStorageDirectory: URL

    /// Opens the Drive folder in Finder just before enumeration to nudge the file provider — set by AppCoordinator.
    private let openDriveFolder: () async -> Void

    /// Kill switch, read lazily so a mid-session flag change applies.
    private let isRefreshEventResyncDisabled: () -> Bool

    private var runMetrics: FullResyncRunMetrics?

    private let waitConfiguration: ReenumerationWaitConfiguration

    // Internal (not private) so coordinator tests can drive the in-flight resync configuration directly.
    var resyncTrigger: ResyncTrigger = .userStarted
    var onReenumerationWillBegin: (@MainActor () async throws -> Void)?
    var onTerminalFailure: (@MainActor () -> Void)?

    /// While a pause is winding down — the engine is still finishing its in-flight metadata request before
    /// it can settle — this holds the user's latest intent. Reconciled in the engine's `onPaused` callback:
    /// `.resume` restarts the scan (the engine is idle by then), `.cancelled` finishes the cancellation, and
    /// `.stayPaused` confirms the pause. Cleared at each `performFullResync` and after reconciling. Touched
    /// only on the main actor (UI taps + onPaused).
    private var windingDownPauseIntent: WindingDownPauseIntent?
    private enum WindingDownPauseIntent { case stayPaused, resume, cancelled }

    /// Timeouts (counted in poll-interval ticks) and polling cadence for the post-resync reenumeration waits.
    /// Defaults match production; tests inject smaller values to exercise timeout routing quickly.
    struct ReenumerationWaitConfiguration {
        var workingSetEnumerationTimeout: Double = 300
        var fetchItemPassFinishFloorTimeout: Double = 300
        var fetchItemPassFinishCeilingTimeout: Double = 1800
        var fetchItemPassFinishSecondsPerNode: Double = 2
        var pollInterval: Duration = .seconds(1)

        static let `default` = ReenumerationWaitConfiguration()
    }

    /// Consecutive quiet polls (no fetch-item-pass or early-exit activity) required before the file
    /// provider is considered idle and the resync is declared finished.
    private static let consecutiveQuietPollsUntilSettled = 15

    convenience init(applicationEventObserver: FullResyncApplicationStateObserverProtocol,
                     domainOperationsService: DomainOperationsServiceProtocol,
                     menuBarCoordinator: MenuBarCoordinator?,
                     openDriveFolder: @escaping () async -> Void = { },
                     isRefreshEventResyncDisabled: @escaping () -> Bool = { false },
                     tower: Tower) {
        self.init(applicationEventObserver: applicationEventObserver,
                  fullResyncService: FullResyncService(tower: tower),
                  domainOperationsService: domainOperationsService,
                  menuBarCoordinator: menuBarCoordinator,
                  openDriveFolder: openDriveFolder,
                  isRefreshEventResyncDisabled: isRefreshEventResyncDisabled)
    }

    init(applicationEventObserver: FullResyncApplicationStateObserverProtocol,
         fullResyncService: FullResyncServiceProtocol,
         domainOperationsService: DomainOperationsServiceProtocol,
         menuBarCoordinator: MenuBarCoordinator?,
         openDriveFolder: @escaping () async -> Void = { },
         isRefreshEventResyncDisabled: @escaping () -> Bool = { false },
         fullResyncMetricsReporter: FullResyncMetricsReporting = FullResyncObservabilityMonitor(),
         dateResource: DateResource = PlatformCurrentDateResource(),
         settingsStorageSuite: SettingsStorageSuite = Constants.appGroup,
         waitConfiguration: ReenumerationWaitConfiguration = .default) {
        Log.trace()

        self.applicationEventObserver = applicationEventObserver
        self.fullResyncService = fullResyncService
        self.domainOperationsService = domainOperationsService
        self.menuBarCoordinator = menuBarCoordinator
        self.openDriveFolder = openDriveFolder
        self.isRefreshEventResyncDisabled = isRefreshEventResyncDisabled
        self.fullResyncMetricsReporter = fullResyncMetricsReporter
        self.dateResource = dateResource
        self.waitConfiguration = waitConfiguration
        self.settingsStorageDirectory = settingsStorageSuite.directoryUrl

        self.observationCenter = UserDefaultsObservationCenter(userDefaults: settingsStorageSuite.userDefaults, additionalLogging: true)

        _shouldReenumerateItems.configure(with: settingsStorageSuite)
        _workingSetEnumerationInProgress.configure(with: settingsStorageSuite)
        _fullResyncInProgress.configure(with: settingsStorageSuite)
        _cannotSynchronizeEarlyExitOccurred.configure(with: settingsStorageSuite)
        _cannotSynchronizeEarlyExitCount.configure(with: settingsStorageSuite)
        _fetchedItemCount.configure(with: settingsStorageSuite)
        _resyncEnumerationPageCount.configure(with: settingsStorageSuite)
        _refreshEventResyncPending.configure(with: settingsStorageSuite)
        _resyncEnumeratedItemCount.configure(with: settingsStorageSuite)
        _resyncEnumeratedItemTotal.configure(with: settingsStorageSuite)

        workingSetEnumerationInProgress = nil
        fullResyncInProgress = nil
        shouldReenumerateItems = .eventLoop
    }

    deinit {
        observationCenter.removeObserver(self)
    }

    /// Whether resolving deferred resync early-exit errors is possible right now: true when sync is
    /// neither paused nor offline, so the domain should be reconnected and `signalErrorResolved` can
    /// take effect. We only observe pause/offline here, not the domain's actual connection state.
    @MainActor
    private var isResolvingResyncEarlyExitErrorsPossible: Bool {
        !applicationEventObserver.state.isPaused && !applicationEventObserver.state.isOffline
    }

    @MainActor
    func performFullResync(onlyIfPreviouslyInterrupted: Bool,
                           trigger: ResyncTrigger,
                           onReenumerationWillBegin: (@MainActor () async throws -> Void)?,
                           onTerminalFailure: (@MainActor () -> Void)?) {
        if trigger.isRefreshEvent {
            // Recorded before the guard below: the events cursor is already gone, so a declined request
            // must still leave the obligation for the next launch.
            refreshEventResyncPending = true
        }
        // Single-flight: a second trigger mid-flight would clobber resyncTrigger/onReenumerationWillBegin/
        // onTerminalFailure and the counters, so ignore it. retryFullResync runs only after a terminal
        // outcome cleared the flag, so it is not blocked. A resume/retry is exempt: it re-drives the
        // paused resync, which deliberately keeps the flag set.
        // A refresh request also checks the state: `.errored` clears the flag while the run is still on
        // screen owning the trigger and the callbacks, and the events loop is running again by then.
        let resyncOwnsTheScreen = fullResyncInProgress == true
            || (trigger.isRefreshEvent && applicationEventObserver.state.fullResyncState.isHappening)
        if resyncOwnsTheScreen && !trigger.isResume {
            Log.debug("Ignoring full resync request because one is already in progress", domain: .resyncing)
            return
        }
        var trigger = trigger
        if onlyIfPreviouslyInterrupted {
            // A pending tag is enough on its own: the owing run may have left no recovery DB, and
            // previousRunWasInterrupted only reports leftovers found at launch.
            let refreshPending = refreshEventResyncPending == true && !isRefreshEventResyncDisabled()
            guard fullResyncService.previousRunWasInterrupted || refreshPending else {
                refreshEventResyncPending = nil // unset, or retired by the kill switch
                Log.debug("Not performing resync because it was not interrupted", domain: .resyncing)
                return
            }
            // Relaunch requests .userStarted; restore the refresh trigger to keep Pause-only controls.
            if refreshEventResyncPending == true {
                if isRefreshEventResyncDisabled() {
                    // Finish as a normal resync, and drop the tag so it can't resurrect.
                    refreshEventResyncPending = nil
                    Log.info("Refresh-event resync is disabled; continuing the interrupted resync as user-started",
                             domain: .resyncing)
                } else {
                    trigger = .refreshEventStarted
                }
            }
        }
        if trigger.isRefreshEvent {
            refreshEventResyncPending = true // the relaunch path may have upgraded the trigger
        }

        self.resyncTrigger = trigger
        self.onReenumerationWillBegin = onReenumerationWillBegin
        self.onTerminalFailure = onTerminalFailure

        // Each run starts with no pause winding down, so a stale intent from an earlier run (one that
        // ended via completion/error rather than onPaused) can't misdirect this run's onPaused reconcile.
        windingDownPauseIntent = nil

        fullResyncInProgress = true
        // Start each resync from a clean slate; the extension sets these when it defers an operation.
        cannotSynchronizeEarlyExitOccurred = false
        cannotSynchronizeEarlyExitCount = 0
        fetchedItemCount = 0
        resyncEnumerationPageCount = 0

        // Drop any diff artifact left by a prior run so this run can't feed the extension a stale diff.
        deleteResyncDiffArtifact()

        resyncEnumeratedItemCount = 0
        resyncEnumeratedItemTotal = 0

        Log.trace()
        let startTime = Date.now
        let resume = trigger.isResume
        if !resume || runMetrics == nil {
            // Fresh run (or a resume with no live run object, e.g. after a relaunch): flush any abandoned
            // prior run, then start a new metrics object. Retry/resume otherwise keep the existing one so
            // its state survives the per-attempt recreation.
            runMetrics?.flushAbandonedIfNeeded()
            runMetrics = FullResyncRunMetrics(reporter: fullResyncMetricsReporter, dateResource: dateResource)
            runMetrics?.attemptWillStart(userAction: resume ? .pauseResume : .firstTry)
        }
        performWithLogging { [weak self] in
            try await self?.applicationEventObserver.fullResyncStarted(isAutomatic: trigger.isRefreshEvent)
            await self?.captureNodeIdentifiersSnapshot(trigger: trigger)
            await self?.fullResyncService.start(
                resume: resume,
                onScanStarted: { scanEngineVersion in
                    // The scan is now cancellable — promote the UI from .starting so Pause/Cancel appear.
                    self?.applicationEventObserver.fullResyncScanStarted(variant: .init(scanEngineVersion: scanEngineVersion))
                    self?.runMetrics?.scanDidStart(engine: self?.fullResyncService.resolvedScanEngineVersion ?? .v1)
                },
                onNodesRefreshed: { saved, total in
                    self?.applicationEventObserver.fullResyncItemCountUpdated(saved: saved, total: total)
                },
                onDoneResyncing: { refreshedNodesReport in
                    // the error is not caught here by design — it should be propagated to fullResyncService which handles it internally
                    try await self?.reenumerateAfterResyncing(refreshedNodesReport: refreshedNodesReport, startTime: startTime)
                },
                onCompleted: {
                    // No pause is settling once the run is over; drop any intent so it can't outlive it.
                    self?.windingDownPauseIntent = nil
                    self?.fullResyncInProgress = false
                    self?.refreshEventResyncPending = nil // rebuilt; nothing left to resume
                    await self?.domainOperationsService.tryResolvingErrors()
                    self?.cannotSynchronizeEarlyExitOccurred = false
                },
                onCancelled: {
                    // The cancel reached the live scan, so this callback owns the teardown; drop the intent
                    // (set by a cancel during the wind-down) so it can't outlive the run.
                    self?.windingDownPauseIntent = nil
                    self?.runMetrics?.reportCancelled()
                    self?.fullResyncInProgress = false
                    self?.routeTerminalFailureIfNeeded()
                    // A login-reconnection cancel before the cache rebuild finished offers recovery
                    // instead of idling; the domain is still disconnected, nothing to resolve here.
                    if self?.surfaceRecoveryIfLoginReconnectionCancelledBeforeRebuild() == true {
                        return
                    }
                    // Cancellation/error can happen after the domain was already reconnected (during
                    // reenumeration), with an operation deferred as .cannotSynchronize in between. No
                    // further reconnection would resolve it, so resolve it here. Gated on pause/offline
                    // so a paused/offline cancel leaves the flag for the next reconnection to consume.
                    let canResolveEarlyExitErrors = self?.isResolvingResyncEarlyExitErrorsPossible == true
                    performWithLogging {
                        try await self?.applicationEventObserver.fullResyncCancelled()
                        if canResolveEarlyExitErrors {
                            await self?.domainOperationsService.tryResolvingCannotSynchronizeErrorIfDeferred()
                        }
                    }
                },
                onPaused: { [weak self] in
                    guard let self else { return }
                    // Reconcile the wind-down: if the user resumed while the engine was finishing its
                    // in-flight request, it is idle now, so restart the scan. Otherwise confirm the pause.
                    let intent = self.windingDownPauseIntent
                    self.windingDownPauseIntent = nil
                    switch intent {
                    case .resume:
                        // Tag the attempt before restarting: performFullResync only arms a fresh metrics
                        // object, so without this the resumed attempt is still reported as .firstTry.
                        self.runMetrics?.attemptWillStart(userAction: .pauseResume)
                        self.resumeFullResync()
                        return
                    case .cancelled:
                        // The user cancelled while this callback was already in flight, so the service took
                        // its non-cancellable branch and already tore the run down (recovery discarded).
                        // Finish the cancellation instead of confirming a pause the user abandoned —
                        // otherwise the tray would show "paused" with operations still deferred.
                        self.runMetrics?.reportCancelled()
                        self.fullResyncInProgress = false
                        performWithLogging {
                            try await self.applicationEventObserver.fullResyncCancelled()
                        }
                        return
                    case .stayPaused, nil:
                        break
                    }
                    // Keep fullResyncInProgress true so the file provider keeps deferring operations; the
                    // service already preserved the recovery DB. Count comes from the last in-progress or
                    // optimistically-paused state. Arm pause/resume for the resumed attempt.
                    self.runMetrics?.attemptWillStart(userAction: .pauseResume)
                    let count: Int
                    switch self.applicationEventObserver.state.fullResyncState {
                    case .inProgress(let saved, _), .paused(let saved): count = saved
                    default: count = 0
                    }
                    performWithLogging {
                        try await self.applicationEventObserver.fullResyncPaused(count: count)
                    }
                },
                onErrored: { error in
                    // The run ended in failure rather than settling into a pause; drop any pending intent.
                    self?.windingDownPauseIntent = nil
                    self?.runMetrics?.reportFailed()
                    // completedWithFailures' per-item v2 failures are already reported individually — don't double-count.
                    if self?.isCompletedWithFailures(error) == false {
                        self?.runMetrics?.reportError(DriveFullResyncErrorType.classify(error))
                    }
                    self?.fullResyncInProgress = false
                    self?.applicationEventObserver.fullResyncErrored(message: error.localizedDescription)
                    self?.routeTerminalFailureIfNeeded()
                    guard self?.isResolvingResyncEarlyExitErrorsPossible == true else { return }
                    performWithLogging {
                        await self?.domainOperationsService.tryResolvingCannotSynchronizeErrorIfDeferred()
                    }
                }
            )
            // Reenumeration removes the snapshot on success; clean it up for paths that skip it (cancel/error).
            self?.deleteNodeIdentifiersTempFile()
            self?.deleteResyncDiffArtifact()
        }
    }

    @MainActor
    private func waitUntilChecks(
        operationName: String? = nil,
        check: @autoclosure () -> Bool,
        body: (Double) async throws -> Void = { _ in }
    ) async throws {
        var seconds: Double = 0
        let interval: Double = Double(self.waitConfiguration.pollInterval.components.seconds)
            + Double(self.waitConfiguration.pollInterval.components.attoseconds) / 1_000_000_000_000_000_000.0
        while check() {
            try await Task.sleep(for: self.waitConfiguration.pollInterval)
            seconds += interval
            if let operationName {
                Log.info("wait on \(operationName): \(seconds) seconds", domain: .application)
            }
            try await body(seconds)
        }
    }

    @MainActor
    func reenumerateAfterResyncing(refreshedNodesReport: RefreshedNodesReport, startTime: Date) async throws {
        Log.trace()
        runMetrics?.enterStatePropagation(finalNodeTotal: refreshedNodesReport.total, activeNodeCount: refreshedNodesReport.active)

        // Reached only after the node-refresh rebuild succeeded. For a login reconnection this hook
        // clears keepDomainDisconnectedForCacheRebuild; from here the DB is fresh, so any later failure
        // is benign and the flag is never re-set to true.
        try await onReenumerationWillBegin?()

        // A recovery resync (set by AppCoordinator when the metadata DB was recreated) keeps its mode, so the
        // file provider re-enumerates items instead of changes. Its snapshot was taken from the recreated store,
        // so it has no previous node ids to diff against and no available-offline marks to restore.
        if shouldReenumerateItems != .recoveryResync {
            let snapshot = await loadResyncSnapshot()

            // Must precede the reconnection below: the first NodeItem the file provider builds reads these flags.
            await restoreMarkedOfflineAvailable(snapshot?.markedOfflineAvailable ?? [])

            // Precompute the delete/update diff from the frozen rebuilt store and write it before the domain
            // reconnects, so the file provider slices the cached diff instead of rescanning on every page.
            await precomputeResyncDiffArtifact(previous: snapshot?.nodeIdentifiers)

            shouldReenumerateItems = .fullResync
        }

        // workingSetEnumerationInProgress is stored in shared user defaults
        // and used for communication with file provider extension, hence observation
        // to detect when the file provider sets the value back to false.
        // Set before reconnecting so completeFullResync can clean up if reconnection fails.
        workingSetEnumerationInProgress = true

        do {
            // The domain must reconnect before the file provider can enumerate. If reconnection fails,
            // finish the resync gracefully and surface the reason as non-blocking feedback rather than
            // leaving the flow hanging or routing to a hard error state.
            try await applicationEventObserver.fullResyncReenumerationStarted()
        } catch {
            Log.error("Full resync reenumeration start failed \(error.localizedDescription)", domain: .resyncing)
            completeFullResync(hasFileProviderResponded: false, warning: error.localizedDescription, startTime: startTime)
            return
        }

        // Opening the Drive folder in Finder nudges the file provider to enumerate it, which makes the
        // post-resync enumeration more reliable.
        await openDriveFolder()

        // Diagnostics for the completion-reason telemetry emitted on the settle and timeout paths below.
        var lastActivitySource = "none"
        var fetchPassSeconds = 0.0

        do {
            // ignoring the error because I'll be repeating the call for enumeration in the wait loop
            try? await domainOperationsService.signalEnumerator(reason: .fullResync)

            // first, wait on the working set enumeration: keep waiting while it is still in progress
            // (flag is true/nil), proceed only once the file provider sets it back to false. The changes
            // enumeration is now paged across re-invocations, so the timeout is per page: each delivered
            // page advances resyncEnumerationPageCount and restarts the clock, so a long multi-page
            // enumeration is not killed as long as it keeps making progress.
            let workingSetTimeout = waitConfiguration.workingSetEnumerationTimeout
            var previousPageCount = resyncEnumerationPageCount ?? 0
            var lastProgressSeconds: Double = 0
            try await waitUntilChecks(operationName: "the working set enumeration",
                                      check: workingSetEnumerationInProgress != false) {
                let currentPageCount = resyncEnumerationPageCount ?? 0
                if currentPageCount != previousPageCount {
                    previousPageCount = currentPageCount
                    lastProgressSeconds = $0
                }
                guard $0 - lastProgressSeconds < workingSetTimeout else {
                    throw FullResyncWaitTimedOut(operation: "working set enumeration", seconds: $0)
                }
                do {
                    try await domainOperationsService.signalEnumerator(reason: .fullResync)
                } catch {
                    Log.error(
                        "Failed to signal enumerator during full resync",
                        error: error,
                        domain: .resyncing
                    )
                }
                let enumerated = resyncEnumeratedItemCount ?? 0
                // Total is unknown until the extension delivers its first page; publish nil until then so the
                // UI shows an indeterminate step instead of a premature "done" from the reset 0. Once a page
                // lands (total written before the page-count bump), publish the real total (0 ⇒ no changes).
                let total: Int? = currentPageCount > 0 ? (resyncEnumeratedItemTotal ?? 0) : nil
                applicationEventObserver.fullResyncReenumerationProgresses(
                    enumerationState: .waitingForTheWorkingSetEnumerationToFinish(seconds: $0, enumerated: enumerated, total: total)
                )
            }

            // second, wait on the fetch item pass to finish. The file provider is idle only once all
            // signals stay unchanged for several consecutive polls: the count of items fetched
            // (monotonic), the early-exit count (monotonic; operations the extension defers as
            // .cannotSynchronize while draining its queue), and the working-set flag staying clear. The
            // counts only ever increase, so an unchanged value across polls truly means no activity.
            // Timeout scales with the number of resynced nodes (roughly 2s/node), with a floor of 5
            // minutes and a ceiling of 30 minutes.
            var previousFetchedItemCount: Int = fetchedItemCount ?? 0
            var previousEarlyExitCount: Int = cannotSynchronizeEarlyExitCount ?? 0
            var consecutiveQuietPolls: Int = 0
            let fetchPassFinishTimeout = min(
                waitConfiguration.fetchItemPassFinishCeilingTimeout,
                max(waitConfiguration.fetchItemPassFinishFloorTimeout,
                    Double(refreshedNodesReport.total) * waitConfiguration.fetchItemPassFinishSecondsPerNode)
            )
            try await waitUntilChecks(check: consecutiveQuietPolls < Self.consecutiveQuietPollsUntilSettled) {
                guard $0 < fetchPassFinishTimeout else {
                    throw FullResyncWaitTimedOut(operation: "fetch item pass to finish", seconds: $0)
                }
                fetchPassSeconds = $0
                let currentFetchedItemCount = fetchedItemCount ?? 0
                let currentEarlyExitCount = cannotSynchronizeEarlyExitCount ?? 0
                // A second working-set enumeration wave during the fetch pass is activity; reset the quiet
                // counter on it, but do not re-enter the working-set wait above.
                let workingSetReentered = workingSetEnumerationInProgress == true
                if currentFetchedItemCount == previousFetchedItemCount && currentEarlyExitCount == previousEarlyExitCount && !workingSetReentered {
                    consecutiveQuietPolls += 1
                    Log.info("wait on the fetch item pass to finish for \($0)s, no activity (fetched \(currentFetchedItemCount), early-exits \(currentEarlyExitCount)), quiet poll \(consecutiveQuietPolls)/\(Self.consecutiveQuietPollsUntilSettled)",
                             domain: .application)
                } else {
                    if currentFetchedItemCount != previousFetchedItemCount {
                        lastActivitySource = "fetched"
                    } else if currentEarlyExitCount != previousEarlyExitCount {
                        lastActivitySource = "earlyExit"
                    } else {
                        lastActivitySource = "workingSetReentry"
                    }
                    Log.info("wait on the fetch item pass to finish for \($0)s, activity: fetched \(previousFetchedItemCount)->\(currentFetchedItemCount), early-exits \(previousEarlyExitCount)->\(currentEarlyExitCount), workingSetReentered \(workingSetReentered)",
                             domain: .application)
                    previousFetchedItemCount = currentFetchedItemCount
                    previousEarlyExitCount = currentEarlyExitCount
                    consecutiveQuietPolls = 0
                }
                applicationEventObserver.fullResyncReenumerationProgresses(enumerationState: .fetchItemPassInProgress(
                    seconds: $0, fetched: currentFetchedItemCount, expected: refreshedNodesReport.active
                ))
            }

            Log.info(
                "Full resync completed in \(Date().timeIntervalSince(startTime))s (fetch pass settled after \(fetchPassSeconds)s): fetched \(fetchedItemCount ?? 0), early-exits \(cannotSynchronizeEarlyExitCount ?? 0), nodes(active/total) \(refreshedNodesReport.active)/\(refreshedNodesReport.total), lastActivity \(lastActivitySource)",
                domain: .resyncing,
                sendToSentryIfPossible: true
            )
            self.completeFullResync(hasFileProviderResponded: true, startTime: startTime)
        } catch {
            Log.error(
                "Full resync did not settle in \(Date().timeIntervalSince(startTime))s; fetch pass ran \(fetchPassSeconds)s, fetched \(fetchedItemCount ?? 0), early-exits \(cannotSynchronizeEarlyExitCount ?? 0), nodes(active/total) \(refreshedNodesReport.active)/\(refreshedNodesReport.total), lastActivity \(lastActivitySource)",
                error: error,
                domain: .resyncing
            )
            self.completeFullResync(hasFileProviderResponded: false, startTime: startTime)
        }
    }

    @MainActor
    private func completeFullResync(hasFileProviderResponded: Bool, warning: String? = nil, startTime: Date) {
        Log.trace(workingSetEnumerationInProgress?.description ?? "n/a")
        guard workingSetEnumerationInProgress != nil else { return }
        observationCenter.removeObserver(self)
        workingSetEnumerationInProgress = nil
        // The extension removes the artifact on its final page; drop it here too for the paths where
        // enumeration never consumed it (e.g. reconnection failed).
        deleteResyncDiffArtifact()
        Log.info("Full resync completed in \(Date().timeIntervalSince(startTime)) seconds",
                 domain: .resyncing)
        applicationEventObserver.fullResyncCompleted(hasFileProviderResponded: hasFileProviderResponded, warning: warning)
        if hasFileProviderResponded {
            runMetrics?.reportSucceeded()
            if let runMetrics { runMetrics.reportStatePropagationSpeed(nodeCount: runMetrics.settledNodeCount) }
            // Snapshot consumed; drop the prewipe file. Kept on failure so a retry can re-promote it.
            deletePrewipeSnapshotFile()
        } else {
            // Enumeration never confirmed: a failed result, but a definitive conclusion — time records completed.
            runMetrics?.reportFailed()
            runMetrics?.reportError(.enumeration)
            runMetrics?.concludeTime(.completed)
            // Partial count: items fetched before the wait gave up.
            runMetrics?.reportStatePropagationSpeed(nodeCount: fetchedItemCount ?? 0)
            routeTerminalFailureIfNeeded()
        }
        menuBarCoordinator?.showMenuProgramatically()
    }

    /// A login-reconnection resync cancelled before the cache rebuild finished must offer recovery
    /// (Retry + "Create new sync folder") instead of silently going idle. The flag still being true
    /// means reenumeration never began, so the domain is still disconnected: route to `.errored`
    /// without re-setting the flag and without reconnecting. Returns true when it routed to recovery,
    /// so the caller skips the normal cancel-to-idle handling.
    @MainActor
    private func surfaceRecoveryIfLoginReconnectionCancelledBeforeRebuild() -> Bool {
        guard resyncTrigger.isLoginReconnection,
              domainOperationsService.keepDomainDisconnectedForCacheRebuild == true else {
            return false
        }
        Log.info("Login-reconnection resync cancelled before the cache rebuild finished; surfacing recovery",
                 domain: .resyncing)
        // The cancel above already concluded this run's time (aborted); recovery re-offers a Retry that would
        // otherwise preserve — and be permanently guarded by — that concluded run. Drop it so the retry is
        // measured as a fresh run.
        runMetrics = nil
        applicationEventObserver.fullResyncErrored(message: Localization.full_resync_cancelled_recovery)
        return true
    }

    /// Notifies the caller that a login-reconnection resync ended terminally (errored, cancelled, or
    /// completed without the file provider responding) so it can offer recovery.
    @MainActor
    private func routeTerminalFailureIfNeeded() {
        switch resyncTrigger {
        case .loginReconnectionStarted, .loginReconnectionResumed:
            onTerminalFailure?()
        case .userStarted, .userContinued, .refreshEventStarted, .refreshEventContinued:
            break // refresh-event failures use the standard .errored view; no recovery routing
        }
    }

    /// True for `FullResyncError.completedWithFailures` — the aggregate of per-item v2 scan failures that were
    /// already reported at their catch sites (`MetadataScan` chunk fetches, `TreeDiscoveryService` folder
    /// listings). The coordinator suppresses the terminal error for it so those aren't counted twice.
    private func isCompletedWithFailures(_ error: Error) -> Bool {
        guard let resyncError = error as? FullResyncService.FullResyncError else { return false }
        if case .completedWithFailures = resyncError { return true }
        return false
    }

    // MARK: - UserActionsDelegate

    func finishFullResync() {
        Log.trace()
        performWithLogging { [weak self] in
            await self?.applicationEventObserver.fullResyncFinished()
        }
    }

    @MainActor
    func retryFullResync() {
        Log.trace()
        runMetrics?.attemptWillStart(userAction: .retry)
        // Continues the preserved recovery DB, keeping the trigger's controls.
        performFullResync(trigger: resyncTrigger.continuation,
                          onReenumerationWillBegin: onReenumerationWillBegin,
                          onTerminalFailure: onTerminalFailure)
    }

    func cancelFullResync() {
        Log.trace()

        // Cancel is only offered in .errored, where onErrored already cleared the flag.
        if resyncTrigger.isRefreshEvent, fullResyncInProgress == true {
            Log.debug("Ignoring cancel: a refresh-event resync cannot be cancelled while it runs", domain: .resyncing)
            return
        }

        reportAbandonedRefreshObligation()
        refreshEventResyncPending = nil // the cancel discharges any refresh obligation

        // A login-reconnection cancel before the rebuild finished surfaces recovery (Retry / Create new
        // sync folder) instead of abandoning; preserve the recovery DB so Retry can continue the scan.
        fullResyncService.cancel(preservingRecovery: resyncTrigger.isLoginReconnection)

        performWithLogging { [weak self] in
            guard let self else { return }
            if await self.surfaceRecoveryIfLoginReconnectionCancelledBeforeRebuild() { return }
            try await self.applicationEventObserver.fullResyncCancelled()
        }
    }

    func pauseFullResync() {
        Log.trace()
        guard !resyncTrigger.isLoginReconnection else {
            Log.debug("Ignoring pause: a login-reconnection resync cannot be paused", domain: .resyncing)
            return
        }
        // Only reflect the pause once the engine accepts it: past the cancellable phase (the DB swap
        // onwards) pause() is a no-op and onPaused never fires, so an optimistic .paused would leave the
        // tray claiming "paused" while the resync runs to completion.
        guard fullResyncService.pause() else {
            Log.debug("Ignoring pause: the resync is past the point where it can be paused", domain: .resyncing)
            return
        }
        // Accepted: reflect it immediately. The engine still finishes its in-flight metadata request before
        // it settles (seconds), and once .paused the observer drops the winding-down progress updates so
        // the percentage stops climbing. Track the wind-down so a quick Resume defers its restart to
        // onPaused (start() no-ops until the engine is idle) instead of being lost.
        windingDownPauseIntent = .stayPaused
        performWithLogging { [weak self] in await self?.applicationEventObserver.fullResyncPauseRequested() }
    }

    @MainActor
    func resumeFullResync() {
        Log.trace()
        if windingDownPauseIntent != nil {
            // The paused engine is still winding down; start() would no-op until it is idle, so defer the
            // restart to the onPaused settle. Flip the UI to preparing now so Resume feels responsive too.
            windingDownPauseIntent = .resume
            performWithLogging { [weak self] in await self?.applicationEventObserver.fullResyncResumeRequested() }
            return
        }
        // Retry's path minus the error telemetry. The continuation trigger bypasses the single-flight
        // guard, and the callbacks must be forwarded: a login reconnection routes failures through them.
        performFullResync(trigger: resyncTrigger.continuation,
                          onReenumerationWillBegin: onReenumerationWillBegin,
                          onTerminalFailure: onTerminalFailure)
    }

    func cancelPausedResync() {
        Log.trace()
        guard !resyncTrigger.isRefreshEvent else {
            Log.debug("Ignoring cancel: a paused refresh-event resync cannot be cancelled", domain: .resyncing)
            return
        }
        reportAbandonedRefreshObligation()
        refreshEventResyncPending = nil

        if windingDownPauseIntent != nil {
            // The optimistic pause is still winding down: the scan task is live and writing its Recovery_
            // store. Cancel the live scan (stopReason → .cancel) and let it unwind through handleError/
            // onCancelled, which reports the cancellation, discards recovery and clears the in-progress
            // flag after the task stops — rather than tearing the store down underneath the running scan
            // (which would also let the scan's later .pause throw flip the UI back to .paused).
            //
            // Recorded rather than cleared: if the scan had already passed its stopReason check, cancel()
            // takes its non-cancellable branch and onCancelled never fires — the in-flight onPaused reads
            // this intent and finishes the cancellation there instead of confirming the pause.
            windingDownPauseIntent = .cancelled
            fullResyncService.cancel(preservingRecovery: false)
            return
        }

        // The engine has settled into .paused (idle), so onCancelled never fires: report and abandon it
        // synchronously. Clear the in-progress flag so the file provider resumes normal operation, and
        // discard the preserved recovery DB.
        runMetrics?.reportCancelled()
        fullResyncInProgress = false
        fullResyncService.discardPreservedRecovery()
        performWithLogging { [weak self] in
            try await self?.applicationEventObserver.fullResyncCancelled()
        }
    }

    /// Writes the canonical snapshot the rebuild has to survive: the node ids the file provider diffs
    /// against, and the marks the restore re-applies. A login reconnection promotes the prewipe file when
    /// present; otherwise the store is read. Best-effort.
    private func captureNodeIdentifiersSnapshot(trigger: ResyncTrigger) async {
        if trigger.isLoginReconnection, promotePrewipeSnapshotIfPresent() {
            return
        }
        guard let storage = fullResyncService.metadataStorage as? StorageManager else { return }
        do {
            let moc = storage.privateChildContext(of: storage.backgroundContext)
            let (ids, marked) = try await storage.fetchNodeIdentifiersSnapshot(moc: moc)
            await moc.perform { moc.reset() }
            try saveResyncSnapshot(ResyncSnapshot(nodeIdentifiers: ids, markedOfflineAvailable: marked))
            Log.info("Full resync — stored \(ids.count) node ids (\(marked.count) marked available offline) in temporary file",
                     domain: .enumerating)
        } catch {
            // Non-fatal: the file provider refreshes per-item when the snapshot is missing.
            Log.error("Failed to save node IDs to temporary file", error: error, domain: .resyncing)
        }
    }

    /// Copies the prewipe snapshot to the canonical file. Returns true when a prewipe file was found.
    private func promotePrewipeSnapshotIfPresent() -> Bool {
        let prewipeURL = settingsStorageDirectory.appendingPathComponent(ResyncEnumerationService.prewipeNodeIdentifiersTempFileName)
        guard FileManager.default.fileExists(atPath: prewipeURL.path) else { return false }
        let canonicalURL = settingsStorageDirectory.appendingPathComponent(ResyncEnumerationService.nodeIdentifiersTempFileName)
        do {
            let data = try Data(contentsOf: prewipeURL, options: [.uncached])
            try data.write(to: canonicalURL, options: [.atomic])
            Log.info("Full resync — promoted the prewipe node-id snapshot to the canonical file", domain: .resyncing)
            return true
        } catch {
            Log.error("Failed to promote the prewipe node-id snapshot", error: error, domain: .resyncing)
            return false
        }
    }

    private func saveResyncSnapshot(_ snapshot: ResyncSnapshot) throws {
        let fileURL = settingsStorageDirectory.appendingPathComponent(ResyncEnumerationService.nodeIdentifiersTempFileName)
        try snapshot.encoded().write(to: fileURL, options: [.atomic])
    }

    private func deleteNodeIdentifiersTempFile() {
        let fileURL = settingsStorageDirectory.appendingPathComponent(ResyncEnumerationService.nodeIdentifiersTempFileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Re-applies the available-offline marks the pre-rebuild snapshot carried, then re-derives inheritance
    /// from the rebuilt tree. Best-effort. Runs off the main actor (the walk can be large).
    private func restoreMarkedOfflineAvailable(_ marked: [NodeIdentifier]) async {
        guard !marked.isEmpty, let storage = fullResyncService.metadataStorage as? StorageManager else {
            return
        }
        do {
            // A pooled context rather than the shared backgroundContext: the walk can register a large subtree,
            // and the pool resets the context on release. Saves reach the other contexts by coordinator merge.
            let report = try await storage.backgroundContextPool.withContext { moc in
                try await storage.restoreMarkedOfflineAvailable(marked, moc: moc)
            }
            Log.info("Full resync — restored \(report.marked)/\(report.requested) marked node(s) (\(report.missing) missing), derived \(report.inherited) inheriting",
                     domain: .offlineAvailable)
        } catch is CancellationError {
            Log.info("Full resync — available offline restore cancelled", domain: .offlineAvailable)
        } catch {
            Log.error("Failed to restore the available offline marks", error: error, domain: .offlineAvailable)
        }
    }

    /// Precomputes the delete/update diff from the frozen rebuilt store against the previous-id snapshot and
    /// writes it for the file provider's fast path. Best-effort: an unreadable store or a missing snapshot
    /// drops a stale artifact so the extension falls back to its own scan. Runs off the main actor (the scan
    /// can be large).
    private func precomputeResyncDiffArtifact(previous: [NodeIdentifier]?) async {
        guard let storage = fullResyncService.metadataStorage as? StorageManager, let previous else {
            deleteResyncDiffArtifact()
            return
        }
        do {
            let moc = storage.privateChildContext(of: storage.backgroundContext)
            let (updateCandidates, deletedState) = try await ResyncDiff.scanIdentifiers(in: moc, batchSize: 1500)
            await moc.perform { moc.reset() }
            let diff = ResyncDiff.computeResyncDiff(
                previous: previous, updateCandidates: updateCandidates, deletedState: deletedState
            )
            try saveResyncDiffArtifact(diff)
            Log.info("Full resync — precomputed diff: \(diff.deletes.count) deletes, \(diff.updates.count) updates",
                     domain: .resyncing)
        } catch {
            Log.error("Failed to precompute resync diff", error: error, domain: .resyncing)
            deleteResyncDiffArtifact()
        }
    }

    /// Reads and decodes the pre-rebuild snapshot once, off the main actor. Nil when it is absent or
    /// unreadable; both consumers degrade to their no-snapshot behaviour.
    private func loadResyncSnapshot() async -> ResyncSnapshot? {
        let fileURL = settingsStorageDirectory.appendingPathComponent(ResyncEnumerationService.nodeIdentifiersTempFileName)
        do {
            let data = try Data(contentsOf: fileURL, options: [.uncached])
            return try ResyncSnapshot.decode(from: data)
        } catch {
            Log.error("Failed to read the resync snapshot", error: error, domain: .resyncing)
            return nil
        }
    }

    private func saveResyncDiffArtifact(_ diff: ResyncDiff) throws {
        let fileURL = settingsStorageDirectory.appendingPathComponent(ResyncDiff.resyncDiffTempFileName)
        try diff.encoded().write(to: fileURL, options: [.atomic])
    }

    private func deleteResyncDiffArtifact() {
        let fileURL = settingsStorageDirectory.appendingPathComponent(ResyncDiff.resyncDiffTempFileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Deletes the prewipe snapshot once it has been consumed.
    private func deletePrewipeSnapshotFile() {
        let fileURL = settingsStorageDirectory.appendingPathComponent(ResyncEnumerationService.prewipeNodeIdentifiersTempFileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Cancelling retires a backend-requested rebuild without performing it, so nothing retries and the
    /// metadata keeps whatever the failed run left. Deliberate — Cancel is the escape hatch from a resync
    /// the user cannot otherwise stop — but it must not be silent.
    private func reportAbandonedRefreshObligation() {
        guard refreshEventResyncPending == true else { return }
        Log.warning("Backend-requested rebuild abandoned on cancel; local metadata may stay stale",
                    domain: .resyncing, sendToSentryIfPossible: true)
    }
}

// MARK: - Prewipe snapshot capture (before the resync coordinator exists)

extension FullResyncCoordinator {

    /// Prewipe snapshot in the app-group container, read by the resync after the rebuild.
    private static var prewipeSnapshotURL: URL {
        Constants.appGroup.directoryUrl.appendingPathComponent(ResyncEnumerationService.prewipeNodeIdentifiersTempFileName)
    }

    /// Captures the snapshot before local metadata is wiped, so a later login-reconnection resync can promote
    /// it, signal the old nodes as deletions, and restore the available-offline marks. Runs off the main
    /// actor (the id list can be very large). Best-effort: on failure any stale snapshot is dropped and the
    /// resync refreshes per-item.
    static func handleResyncSnapshotBeforeWipe(from storage: StorageManager) async {
        guard let (ids, marked) = try? await storage.fetchNodeIdentifiersSnapshot() else {
            Log.warning("Could not read node IDs before the volume-lock wipe; the resync will refresh per-item", domain: .application)
            deletePrewipeResyncSnapshot()
            return
        }
        let url = prewipeSnapshotURL
        let snapshot = ResyncSnapshot(nodeIdentifiers: ids, markedOfflineAvailable: marked)
        do {
            try await Task.detached(priority: .userInitiated) {
                try snapshot.encoded().write(to: url, options: [.atomic])
            }.value
            Log.info("Captured \(ids.count) node ids (\(marked.count) marked available offline) before the volume-lock wipe",
                     domain: .application)
        } catch {
            Log.error("Failed to capture prewipe node IDs", error: error, domain: .application)
        }
    }

    /// Removes the prewipe snapshot when recovery is abandoned or the account is signed out.
    static func deletePrewipeResyncSnapshot() {
        try? FileManager.default.removeItem(at: prewipeSnapshotURL)
    }

    /// Drops the refresh tag on sign-out.
    static func clearRefreshEventResyncTag() {
        Constants.appGroup.userDefaults.removeObject(forKey: UserDefaults.FileProvider.refreshEventResyncPendingKey.rawValue)
    }
}
