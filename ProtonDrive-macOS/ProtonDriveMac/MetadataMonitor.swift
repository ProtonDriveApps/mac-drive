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

/// Monitors any changes to the metadata DB and updates the app's behavior accordingly
class MetadataMonitor {

    let syncErrorDBUpdatePublisher = PassthroughSubject<Int, Never>()

    let storage: StorageManager
    let syncStorage: SyncStorageManager?
    let sessionVault: SessionVault

    private let eventsProcessor: EventsSystemManager
    private let observationCenter: UserDefaultsObservationCenter

    private var askedToStartEventsProcessor = false

    init(eventsProcessor: EventsSystemManager,
         storage: StorageManager,
         syncStorage: SyncStorageManager?,
         sessionVault: SessionVault,
         observationCenter: UserDefaultsObservationCenter) {
        self.eventsProcessor = eventsProcessor
        self.storage = storage
        self.syncStorage = syncStorage
        self.sessionVault = sessionVault
        self.observationCenter = observationCenter

        self.cleanSyncStorage()
        self.manageEventSystem()

        observationCenter.addObserver(self, of: \.metadataDBUpdate) { [unowned self] _ in
            self.metadataDBUpdated()
        }

        observationCenter.addObserver(self, of: \.syncErrorDBUpdate) { [unowned self] _ in
            guard let storage = self.syncStorage else {
                Log.error("Storage for Syncing not found", domain: .storage)
                return
            }
            let errorsCount = storage.syncErrorsCount(in: storage.mainContext)
            self.syncErrorDBUpdatePublisher.send(errorsCount)
        }
    }

    deinit {
        observationCenter.removeObserver(self)
        eventsProcessor.pauseEventsSystem()
    }

    private func metadataDBUpdated() {
        manageEventSystem()
    }

    /// Starts or stops the event system depending on the state of the metadata DB
    private func manageEventSystem() {
        let moc = self.storage.backgroundContext
        moc.performAndWait {
            let addressIDs = self.sessionVault.addressIDs
            if let mainShare = storage.mainShareOfVolume(by: addressIDs, moc: moc) {
                guard !askedToStartEventsProcessor && !eventsProcessor.eventProcessorIsRunning else { return } // already started

                self.askedToStartEventsProcessor = true
                self.eventsProcessor.runEventsSystem()
            } else {
                guard eventsProcessor.eventProcessorIsRunning else { return } // already stopped

                self.eventsProcessor.pauseEventsSystem()
                self.askedToStartEventsProcessor = false
            }
        }
    }

    private func cleanSyncStorage() {
        if let syncStorage {
            let moc = syncStorage.mainContext
            do {
                try syncStorage.deleteSyncItems(olderThan: syncStorage.oldItemsRelativeDate, in: moc)
            } catch {
                Log.error("Failed to delete sync items: \(error.localizedDescription)", domain: .storage)
            }
        }
    }
}
