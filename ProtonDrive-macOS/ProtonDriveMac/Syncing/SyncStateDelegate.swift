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

import Combine
import FileProvider
import PDCore

public protocol SyncStateDelegateProtocol {
    /// Called when isPaused, isOffline, the volume lock, or the fullResync status changes.
    /// Callers report the current facts; deriving the effective state (and its priority) is this delegate's job.
    func updateState(paused: Bool, offline: Bool, volumeLocked: Bool, fullResync: (shouldDisconnectDomain: Bool, shouldPauseEvents: Bool)) async throws
}

/// A protocol so the priority resolution is testable.
protocol SyncStateDomainOperations: AnyObject {
    func syncWasPaused() async throws
    func performingFullResync() async throws
    func networkConnectionLost() async throws
    func syncWasResumed() async throws
}

extension DomainOperationsService: SyncStateDomainOperations {}

/// Propagates changes in `isPaused`, `isOffline` and the volume lock to `EventsSystemManager` and `DomainOperationsService`.
public final class SyncStateDelegate: SyncStateDelegateProtocol {
        private enum EffectiveSyncState {
        case volumeLocked
        case fullResync
        case paused
        case offline
        case active

        init(volumeLocked: Bool, fullResync: Bool, paused: Bool, offline: Bool) {
            if volumeLocked {
                self = .volumeLocked
            } else if fullResync {
                self = .fullResync
            } else if paused {
                self = .paused
            } else if offline {
                self = .offline
            } else {
                self = .active
            }
        }
    }

    private let eventsProcessor: EventsSystemManager
    private let domainOperationsService: SyncStateDomainOperations

    init(eventsProcessor: EventsSystemManager, domainOperationsService: SyncStateDomainOperations) {
        self.eventsProcessor = eventsProcessor
        self.domainOperationsService = domainOperationsService
        Log.info("Sync Monitor: initialized", domain: .syncing)
    }

    public func updateState(paused: Bool, offline: Bool, volumeLocked: Bool, fullResync: (shouldDisconnectDomain: Bool, shouldPauseEvents: Bool)) async throws {
        Log.info("SyncMonitor: Syncing state updated to (paused: \(paused), offline: \(offline), volumeLocked: \(volumeLocked))", domain: .syncing)

        let shouldRunEvents = !volumeLocked && !fullResync.shouldPauseEvents && !paused && !offline
        if shouldRunEvents {
            eventsProcessor.runEventsSystem()
        } else {
            eventsProcessor.pauseEventsSystem()
        }

        let domainState = EffectiveSyncState(volumeLocked: volumeLocked, fullResync: fullResync.shouldDisconnectDomain, paused: paused, offline: offline)

        switch domainState {
        case .volumeLocked, .paused:
            try await domainOperationsService.syncWasPaused()
        case .fullResync:
            try await domainOperationsService.performingFullResync()
        case .offline:
            try await domainOperationsService.networkConnectionLost()
        case .active:
            try await domainOperationsService.syncWasResumed()
        }
    }
}
