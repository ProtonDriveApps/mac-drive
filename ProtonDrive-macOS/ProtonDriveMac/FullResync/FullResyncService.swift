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

protocol FullResyncServiceProtocol {
    func start(onNodesRefreshed: @MainActor @escaping (Int) -> Void,
               onDoneResyncing: @MainActor () async throws -> Void,
               onCompleted: @MainActor () async throws -> Void,
               onCancelled: @MainActor () -> Void,
               onErrored: @MainActor (Error) -> Void) async
    func cancel()
    var previousRunWasInterrupted: Bool { get }
}

/// Performs the resync, managing the event system and storage.
final class FullResyncService: FullResyncServiceProtocol {
    
    typealias PersistentStoreInfos = (existing: PersistentStoreInfo, recovery: PersistentStoreInfo)
    
    enum FullResyncStage {
        case idle
        case eventsStopped
        case metadataRecoverySetup(metadata: (existing: PersistentStoreInfo, recovery: PersistentStoreInfo?))
        case eventRecoverySetup(metadata: PersistentStoreInfos, events: (existing: PersistentStoreInfo, recovery: PersistentStoreInfo?))
        case refreshFinished(metadata: PersistentStoreInfos, events: PersistentStoreInfos)
        case enumeratingAfterResync
        case metadataReplacedWithRecovery(events: PersistentStoreInfos)
        case eventsReplacedWithRecovery

        /// Can the resync be cancelled at this stage?
        var isCancellable: Bool {
            switch self {
            case .metadataReplacedWithRecovery, .eventsReplacedWithRecovery, .enumeratingAfterResync, .idle:
                false
            case .eventsStopped, .metadataRecoverySetup, .eventRecoverySetup, .refreshFinished:
                true
            }
        }
    }

    private var resyncStage: FullResyncStage = .idle {
        didSet {
            Log.trace("Resync did set resyncStage to \(resyncStage)")
        }
    }

    private let cloudSlot: CloudSlotProtocol
    private let metadataStorage: RecoverableStorage
    private let syncStorage: RecoverableStorage?
    private let eventStorage: RecoverableStorage
    private let nodeRefresher: RefreshingNodesServiceProtocol
    private let startEvents: () -> Void
    private let pauseEvents: () -> Void
    private let clearAndReinitializeEvents: () async throws -> Void
    private var cancelToken: CancelToken?

    var previousRunWasInterrupted: Bool {
        metadataStorage.previousRunWasInterrupted
    }

    convenience init(tower: Tower) {
        self.init(
            metadataStorage: tower.storage,
            syncStorage: tower.syncStorage,
            eventStorage: tower.eventStorageManager,
            cloudSlot: tower.cloudSlot,
            nodeRefresher: tower.refresher,
            startEvents: { [weak tower] in tower?.runEventsSystem() },
            pauseEvents: { [weak tower] in tower?.pauseEventsSystem() },
            clearAndReinitializeEvents: { [weak tower] in
                await tower?.cleanUpEventsAndMetadata(cleanupStrategy: .cleanEvents)
                try tower?.intializeEventsSystem(includeAllVolumes: false)
            }
        )
    }
    
    init(metadataStorage: RecoverableStorage,
         syncStorage: RecoverableStorage?,
         eventStorage: RecoverableStorage,
         cloudSlot: CloudSlotProtocol,
         nodeRefresher: RefreshingNodesServiceProtocol,
         startEvents: @escaping () -> Void,
         pauseEvents: @escaping () -> Void,
         clearAndReinitializeEvents: @escaping () async throws -> Void) {
        Log.trace()
        self.metadataStorage = metadataStorage
        self.syncStorage = syncStorage
        self.eventStorage = eventStorage
        self.cloudSlot = cloudSlot
        self.nodeRefresher = nodeRefresher
        self.startEvents = startEvents
        self.pauseEvents = pauseEvents
        self.clearAndReinitializeEvents = clearAndReinitializeEvents
    }

    func start(onNodesRefreshed: @MainActor @escaping (Int) -> Void,
               onDoneResyncing: @MainActor () async throws -> Void,
               onCompleted: @MainActor () async throws -> Void,
               onCancelled: @MainActor () -> Void,
               onErrored: @MainActor (Error) -> Void
    ) async {
        guard case .idle = resyncStage else { return }

        Log.trace()
        do {
            cancelToken = CancelToken()
            
            // 0. Clear the old recovery and backup ones
            try await performIfNotCancelled { _ = cleanupLeftoversFromPreviousRecoveryAttempt() }

            // 1. Stop event loops
            try await performIfNotCancelled { stopEvents() }

            // 2. Backup all DBs
            let metadata = try await performIfNotCancelled { try setupMetadataRecovery() }
            let events = try await performIfNotCancelled { try setupEventRecovery(metadata: metadata) }

            // 3. Bootstrap the new recovery DB
            let root = try await performIfNotCancelled { try await fetchRootFolder() }
            
            // 4. Perform the refresh
            try await performIfNotCancelled { try await performRefresh(metadata, events, root, onNodesRefreshed) }
            
            // Do not check the cancellation token past this point — if we got to a refreshed state, just finish the operation

            // 5. Replace the old DBs with recovery DBs
            try metadataStorage.replaceExistingDBWithRecovery(existing: metadata.existing, recovery: metadata.recovery)
            resyncStage = .metadataReplacedWithRecovery(events: events)
            
            try eventStorage.replaceExistingDBWithRecovery(existing: events.existing, recovery: events.recovery)
            resyncStage = .eventsReplacedWithRecovery
            
            // 6. Enumerate
            resyncStage = .enumeratingAfterResync

            // 7. Restart the event loop
            try await clearAndReinitializeEvents()
            startEvents()

            // 8. Trigger enumeration and wait for it to complete

            try await onDoneResyncing()

            // 9. Mark resync operation as completed
            resyncStage = .idle
            try await onCompleted()
        } catch {
            let wasCancelled = await handleError(error, resyncStage)
            resyncStage = .idle

            if wasCancelled {
                await onCancelled()
            } else {
                Log.error("Full resync errored: \(error.localizedDescription)", domain: .resyncing)
                await onErrored(error)
            }
        }
    }
    
    func cancel() {
        cancelToken?.cancel()

        if resyncStage.isCancellable {
            // Before a certain stage, we mark the resync as cancelled, and subsequent steps will be skipped due to a userCancelled error being thrown.
            Log.trace("cancel")
        } else {
            // After the resync is no longer cancellable, we directly leave Resync mode.
            Log.trace("abort")
            resyncStage = .idle
        }
    }

    // MARK: - Private methods
    
    private func performIfNotCancelled<T>(_ block: () async throws -> T) async throws -> T {
        guard await cancelToken?.isCancelled != true else {
            Log.trace("cancelled")
            throw CocoaError(.userCancelled)
        }
        Log.trace()
        return try await block()
    }
    
    private func cleanupLeftoversFromPreviousRecoveryAttempt() -> Bool {
        Log.trace()
        let metadataStorageExistedBefore = metadataStorage.cleanupLeftoversFromPreviousRecoveryAttempt()
        let eventStorageExistedBefore = eventStorage.cleanupLeftoversFromPreviousRecoveryAttempt()
        return metadataStorageExistedBefore || eventStorageExistedBefore
    }
    
    private func stopEvents() {
        Log.trace()
        pauseEvents()
        resyncStage = .eventsStopped
    }
    
    private func setupMetadataRecovery() throws -> PersistentStoreInfos {
        Log.trace()
        let existingMetadata = try metadataStorage.disconnectExistingDB()
        resyncStage = .metadataRecoverySetup(metadata: (existingMetadata, nil))
        let recoveryMetadata = try metadataStorage.createRecoveryDB(nextTo: existingMetadata)
        resyncStage = .metadataRecoverySetup(metadata: (existingMetadata, recoveryMetadata))
        return (existingMetadata, recoveryMetadata)
    }
    
    private func setupEventRecovery(metadata: PersistentStoreInfos) throws -> PersistentStoreInfos {
        Log.trace()
        let existingEvents = try eventStorage.disconnectExistingDB()
        resyncStage = .eventRecoverySetup(metadata: metadata, events: (existingEvents, nil))
        let recoveryEvents = try eventStorage.createRecoveryDB(nextTo: metadata.existing)
        resyncStage = .eventRecoverySetup(metadata: metadata, events: (existingEvents, recoveryEvents))
        return (existingEvents, recoveryEvents)
    }
    
    private func fetchRootFolder() async throws -> Folder {
        Log.trace()
        let share = try await cloudSlot.scanRootsAsync(isPhotosEnabled: false)
        let root = await cloudSlot.moc.perform {
            share?.root as? Folder
        }
        guard let root else {
            throw NSError(domain: "me.proton.drive.fullResyncService", code: 1,
                          localizedDescription: "No root folder found")
        }
        return root
    }
    
    private func performRefresh(_ metadata: FullResyncService.PersistentStoreInfos,
                                _ events: FullResyncService.PersistentStoreInfos,
                                _ root: Folder,
                                _ onNodesRefreshed: @MainActor @escaping (Int) -> Void) async throws {
        Log.trace()
        try await nodeRefresher.refreshUsingEagerSyncApproach(
            root: root, shouldIncludeDeletedItems: true, cancelToken: cancelToken, onNodesRefreshed: onNodesRefreshed
        )
        cancelToken = nil
        resyncStage = .refreshFinished(metadata: metadata, events: events)
    }
    
    private func handleError(_ error: Error, _ resyncStage: FullResyncStage) async -> Bool {
        Log.trace("\(resyncStage)")
        switch resyncStage {
        case .idle:
            guard let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled else { return false }
            return true
        case .eventsStopped:
            startEvents()
            return await handleError(error, .idle)
        case let .metadataRecoverySetup(metadata: (existing, recovery)):
            do {
                try metadataStorage.reconnectExistingDBAndDiscardRecoveryIfNeeded(existing: existing, recovery: recovery)
            } catch {
                metadataStorage.cleanupLeftoversFromPreviousRecoveryAttempt()
            }
            return await handleError(error, .eventsStopped)
        case let .eventRecoverySetup((metadataExisting, metadataRecovery), (eventsExisting, eventsRecovery)):
            do {
                try eventStorage.reconnectExistingDBAndDiscardRecoveryIfNeeded(existing: eventsExisting,
                                                                               recovery: eventsRecovery)
            } catch {
                eventStorage.cleanupLeftoversFromPreviousRecoveryAttempt()
            }
            return await handleError(error, .metadataRecoverySetup(metadata: (metadataExisting, metadataRecovery)))
        case let .refreshFinished(metadata, events):
            // error here means we tried to replace existing DB with recovery, but we failed. Let's revert the whole operation
            return await handleError(error, .eventRecoverySetup(metadata: metadata, events: events))
        case .metadataReplacedWithRecovery:
            // Error here means we managed to replace existing DB with recovery, but we failed to do the same for events.
            // We will try clearing the events and restarting them.
            return await handleError(error, .eventsReplacedWithRecovery)
        case .eventsReplacedWithRecovery:
            do {
                try await clearAndReinitializeEvents()
                startEvents()
            } catch {
                // There is no good path from here. Initialization of events failed. The event loop will not work.
                // It will start working on the next app start though. I think we don't have anything better
                // but to log and ignore, it's better than crashing the app.
                Log.error("Events loop reinitialization failed", error: error, domain: .events)
            }
            return await handleError(error, .idle)
        case .enumeratingAfterResync:
            return await handleError(error, .idle)
        }
    }
}
