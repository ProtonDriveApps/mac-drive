// Copyright (c) 2026 Proton AG
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

protocol VolumeLockResolving: AnyObject {
    func fetchVolumeLockStateInputs() async throws -> VolumeLockStateInputs
}

extension Tower: VolumeLockResolving {}

@MainActor
protocol VolumeLockLifecycleDelegate: AnyObject {
    var volumeLockResolver: VolumeLockResolving? { get }
    var didStartPostLoginServices: Bool { get }
    
    func startPostLoginServices() async throws
    func recoverLockedVolumeReplacingLocalState() async throws
}

@MainActor
final class VolumeLockLifecycleController {
    enum Trigger: Equatable {
        case launch
        case poll
        case eventLockHint
        case fileProviderHint
        case userResume

        var isHint: Bool {
            return self == .eventLockHint || self == .fileProviderHint
        }
    }

    enum Outcome: Equatable {
        case active
        case enteredLockedMode
        case alreadyLocked
        case recovered
    }

    weak var delegate: VolumeLockLifecycleDelegate?

    private let appState: ApplicationState
    private let timerResource: TimerResource
    private let pollingInterval: TimeInterval
    private let hintThrottleInterval: TimeInterval

    private var syncStateDelegate: SyncStateDelegateProtocol?
    private var inFlightReconcile: Task<Outcome, Error>?
    private var lastSuccessfulResolutionTime: Date?
    private var pollingTimerHandle: ScheduledTimerHandle?

    var isPollingForLockedVolumeRecovery: Bool {
        pollingTimerHandle != nil
    }

    init(
        appState: ApplicationState,
        timerResource: TimerResource = PlatformTimerResource(),
        pollingInterval: TimeInterval = 5 * 60,
        hintThrottleInterval: TimeInterval = 30
    ) {
        self.appState = appState
        self.timerResource = timerResource
        self.pollingInterval = pollingInterval
        self.hintThrottleInterval = hintThrottleInterval
    }

    func setSyncStateDelegate(_ syncStateDelegate: SyncStateDelegateProtocol?) {
        self.syncStateDelegate = syncStateDelegate
    }

    nonisolated func makeEventsListener() -> EventsListener {
        VolumeLockEventsListener(controller: self)
    }

    func reset() {
        stopPolling()
        syncStateDelegate = nil
        lastSuccessfulResolutionTime = nil
        appState.setVolumeLocked(false)
    }

    @discardableResult
    func reconcile(trigger: Trigger) async throws -> Outcome {
        // Hints arrive in bursts; a recent successful resolution already answered them.
        if trigger.isHint, let last = lastSuccessfulResolutionTime, Date().timeIntervalSince(last) < hintThrottleInterval {
            return appState.isVolumeLocked ? .alreadyLocked : .active
        }

        // Hints are answered by a resolution already in flight; deliberate triggers get a fresh one
        // after it, because callers gate real decisions on the outcome.
        while let inFlightReconcile {
            let outcome = try? await inFlightReconcile.value
            if trigger.isHint, let outcome { return outcome }
        }

        let task = Task { () throws -> Outcome in
            // Cleared inside the task so it is already nil when waiters resume — clearing in the
            // caller can starve the actor: awaiting a completed task doesn't suspend, so a waiter's
            // re-check loop would spin before the caller's defer ever runs.
            defer { inFlightReconcile = nil }
            return try await reconcileOnce(trigger: trigger)
        }
        inFlightReconcile = task
        return try await task.value
    }

    private func reconcileOnce(trigger: Trigger) async throws -> Outcome {
        // A live sync-state delegate is the session marker: nothing to reconcile outside a session.
        guard syncStateDelegate != nil, let volumeLockResolver = delegate?.volumeLockResolver else {
            return appState.isVolumeLocked ? .alreadyLocked : .active
        }

        let inputs = try await volumeLockResolver.fetchVolumeLockStateInputs()
        lastSuccessfulResolutionTime = Date()

        // Don't transition a session that signed out while the fetch was in flight.
        guard syncStateDelegate != nil else { return .active }

        let volumeLockState = VolumeLockState.resolve(from: inputs)

        Log.info("Volume lock lifecycle reconciliation triggered by \(trigger): \(volumeLockState)", domain: .application)

        switch volumeLockState {
        case .cachedVolumeActive:
            guard appState.isVolumeLocked else { return .active }
            return try await recoverSameVolume()

        case .noCachedVolume:
            guard appState.isVolumeLocked else { return .active }
            // Locked with no cached tree = a recovery that wiped and failed before bootstrapping;
            // resume the rebuild — the light path would reconnect the domain to an empty DB.
            return try await recoverReplacingLocalState(trigger: trigger)

        case .noActiveMainVolume:
            return await enterLockedMode(trigger: trigger)

        case .cachedVolumeStale:
            return try await recoverReplacingLocalState(trigger: trigger)

        case .cachedVolumeUnlisted:
            // Another account's cache is a user switch, not a lock event; the login flow owns it.
            return appState.isVolumeLocked ? .alreadyLocked : .active
        }
    }

    private func recoverReplacingLocalState(trigger: Trigger) async throws -> Outcome {
        // Lock first: it keeps the File Provider off the store being wiped, and a failed rebuild
        // leaves the app consistently locked.
        if !appState.isVolumeLocked {
            _ = await enterLockedMode(trigger: trigger)
        }
        guard let delegate else { return .alreadyLocked }
        Log.info("Volume is now active but stale locally. Recovering...", domain: .application, sendToSentryIfPossible: true)
        try await delegate.recoverLockedVolumeReplacingLocalState()
        // Don't transition a session that signed out while the rebuild was in flight.
        guard syncStateDelegate != nil else { return .active }
        // No await before clearing: the rebuild ends in a fire-and-forget resync whose first MainActor
        // job must observe the lock cleared, or its pushes keep the domain paused.
        appState.setVolumeLocked(false)
        stopPolling()
        return .recovered
    }

    private func enterLockedMode(trigger: Trigger) async -> Outcome {
        guard !appState.isVolumeLocked else {
            // Re-assert the (idempotent) pause: the original push may have failed, and waiting for an
            // unrelated sync-state change to forward the flag can take forever.
            do {
                try await pushSyncState(volumeLocked: true)
            } catch {
                Log.error("Failed to re-assert pause for locked volume", error: error, domain: .application)
            }
            startPollingForLockedVolumeRecoveryIfNeeded()
            return .alreadyLocked
        }

        Log.info("Entering locked mode (triggered by \(trigger))", domain: .application, sendToSentryIfPossible: true)
        // Flag first, so sync-state updates landing inside the pause await already see the lock.
        appState.setVolumeLocked(true)
        do {
            try await pushSyncState(volumeLocked: true)
        } catch {
            Log.error("Failed to pause sync for locked volume", error: error, domain: .application)
        }
        startPollingForLockedVolumeRecoveryIfNeeded()
        return .enteredLockedMode
    }

    private func recoverSameVolume() async throws -> Outcome {
        do {
            Log.info("Locked volume is active again - recovering it", domain: .application)
            if delegate?.didStartPostLoginServices != true {
                try await delegate?.startPostLoginServices()
            }
            try await pushSyncState(volumeLocked: false)
            appState.setVolumeLocked(false)
            stopPolling()
            return .recovered
        } catch {
            Log.error("Failed to recover volume", error: error, domain: .application)
            throw error
        }
    }

    private func pushSyncState(volumeLocked: Bool) async throws {
        guard let syncStateDelegate else {
            Log.warning("No sync-state delegate while pushing volumeLocked=\(volumeLocked)", domain: .application)
            return
        }
        
        try await syncStateDelegate.updateState(
            paused: appState.isPaused,
            offline: appState.isOffline,
            volumeLocked: volumeLocked,
            fullResync: appState.fullResyncState.syncStateModifications
        )
    }

    private func startPollingForLockedVolumeRecoveryIfNeeded() {
        guard pollingTimerHandle == nil else { return }

        pollingTimerHandle = timerResource.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] in
            Task { @MainActor [weak self] in
                do {
                    _ = try await self?.reconcile(trigger: .poll)
                } catch {
                    Log.error("Locked-volume polling failed", error: error, domain: .application)
                }
            }
        }
    }

    private func stopPolling() {
        pollingTimerHandle?.invalidate()
        pollingTimerHandle = nil
    }
}

private final class VolumeLockEventsListener: EventsListener, @unchecked Sendable {
    private weak var controller: VolumeLockLifecycleController?

    init(controller: VolumeLockLifecycleController) {
        self.controller = controller
    }

    func processorReceivedEvents() {}

    func processorAppliedEvents(affecting: [NodeIdentifier]) {}

    func rootMetadataMayHaveChanged(volumeID: String) {
        Task { @MainActor [weak controller] in
            do {
                try await controller?.reconcile(trigger: .eventLockHint)
            } catch {
                Log.error("Locked-volume event hint failed", error: error, domain: .application)
            }
        }
    }
}
