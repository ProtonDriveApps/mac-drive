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

public protocol SyncMonitorProtocol {
    func updateState(_ state: SyncMonitor.PauseState, offline: Bool)
}

public final class SyncMonitor: SyncMonitorProtocol {
    
    private let eventsProcessor: EventsSystemManager
    private let domainOperationsService: DomainOperationsService

    private var syncInProgress: Bool = false

    public init(eventsProcessor: EventsSystemManager, domainOperationsService: DomainOperationsService) {
        self.eventsProcessor = eventsProcessor
        self.domainOperationsService = domainOperationsService
        Log.info("Sync Monitor: initialized", domain: .syncing)
    }

    public func updateState(_ state: PauseState, offline: Bool) {
        Log.info("SyncMonitor: Syncing state updated to: \(state)", domain: .syncing)
        self.updateEventsProcessor(state: state, offline: offline)
        self.notifyFileProvider(forState: state, offline: offline)
    }

    private func updateEventsProcessor(state: PauseState, offline: Bool) {
        if state == .active && !offline {
            eventsProcessor.runEventsSystem()
        } else {
            eventsProcessor.pauseEventsSystem()
        }
    }

    private func notifyFileProvider(forState state: PauseState, offline: Bool) {
        #if os(macOS)
        Task {
            switch (state, offline) {
            case (.paused, _):
                try? await domainOperationsService.domainWasPaused()
            case (.active, true):
                try? await domainOperationsService.networkConnectionLost()
            case (.active, false):
                try? await domainOperationsService.domainWasResumed()
            }
        }
        #endif
    }
}

// MARK: - Enums

public extension SyncMonitor {

    enum PauseState: String {
        case active
        case paused
    }

    enum SyncState: String {
        case syncing
        case synced
    }

}
