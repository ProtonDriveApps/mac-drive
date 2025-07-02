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
    /// Called when either isPaused or isOffline or fullResync status changes.
    func updateState(paused: Bool, offline: Bool, fullResyncInProgress: Bool) async throws
}

/// Propagates changes in `isPaused` and `isOffline` to `EventsSystemManager` and `DomainOperationsService`.
public final class SyncStateDelegate: SyncStateDelegateProtocol {
    
    private let eventsProcessor: EventsSystemManager
    private let domainOperationsService: DomainOperationsService
    
    public init(eventsProcessor: EventsSystemManager, domainOperationsService: DomainOperationsService) {
        self.eventsProcessor = eventsProcessor
        self.domainOperationsService = domainOperationsService
        Log.info("Sync Monitor: initialized", domain: .syncing)
    }
    
    public func updateState(paused: Bool, offline: Bool, fullResyncInProgress: Bool) async throws {
        Log.info("SyncMonitor: Syncing state updated to (paused: \(paused), offline: \(offline))", domain: .syncing)
        updateEventsProcessor(paused: paused, offline: offline)
        try await notifyFileProvider(paused: paused, offline: offline, fullResyncInProgress: fullResyncInProgress)
    }
    
    private func updateEventsProcessor(paused: Bool, offline: Bool) {
        if !paused && !offline {
            eventsProcessor.runEventsSystem()
        } else {
            eventsProcessor.pauseEventsSystem()
        }
    }
    
    private func notifyFileProvider(paused: Bool, offline: Bool, fullResyncInProgress: Bool) async throws {
        switch (paused, offline, fullResyncInProgress) {
        case (_, _, true):
            try await domainOperationsService.performingFullResync()
        case (true, _, false):
            try await domainOperationsService.domainWasPaused()
        case (false, true, false):
            try await domainOperationsService.networkConnectionLost()
        case (false, false, false):
            try await domainOperationsService.domainWasResumed()
        }
    }
}
