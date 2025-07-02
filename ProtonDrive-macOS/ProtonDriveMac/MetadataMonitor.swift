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
import Foundation
import PDCore

/// Monitors changes to UserDefaults which indicate that the metadata DB has been updated, and propagates them to `EventsSystemManager`.
/// The changes are saved to UserDefaults by the File Provider, and observed by `SyncObserver`.
/// The observed property is called `metadataDBUpdate` and contains the timestamp of the latest update.
/// There are also a `syncErrorDBUpdate` and `syncing` properties, but those are observed by `SyncObserver` directly.
class MetadataMonitor {

    let storage: StorageManager
    let sessionVault: SessionVault

    private let eventsProcessor: EventsSystemManager
    private let observationCenter: UserDefaultsObservationCenter

    private var askedToStartEventsProcessor = false

    init(eventsProcessor: EventsSystemManager,
         storage: StorageManager,
         sessionVault: SessionVault,
         observationCenter: UserDefaultsObservationCenter) {
        self.eventsProcessor = eventsProcessor
        self.storage = storage
        self.sessionVault = sessionVault
        self.observationCenter = observationCenter

        Log.trace()
    }

    func startObserving() {
        self.toggleEventSystem()

        observationCenter.addObserver(self, of: \.metadataDBUpdate) { [unowned self] _ in
            Log.trace("metadataDBUpdate updated")
            self.toggleEventSystem()
        }
    }

    private func stopObserving() {
        observationCenter.removeObserver(self)
        eventsProcessor.pauseEventsSystem()
    }

    /// Starts or stops the event system depending on the state of the metadata DB
    private func toggleEventSystem() {
        Log.trace()

        let moc = self.storage.backgroundContext
        moc.performAndWait {
            let addressIDs = self.sessionVault.addressIDs
            if storage.mainShareOfVolume(by: addressIDs, moc: moc) != nil {
                Log.trace("Has mainShareOfVolume")
                guard !askedToStartEventsProcessor && !eventsProcessor.eventProcessorIsRunning else { return } // already started

                self.askedToStartEventsProcessor = true
                self.eventsProcessor.runEventsSystem()
            } else {
                Log.trace("No mainShareOfVolume")
                guard eventsProcessor.eventProcessorIsRunning else { return } // already stopped

                self.eventsProcessor.pauseEventsSystem()
                self.askedToStartEventsProcessor = false
            }
        }
    }

    deinit {
        Log.trace()
        stopObserving()
    }
}
