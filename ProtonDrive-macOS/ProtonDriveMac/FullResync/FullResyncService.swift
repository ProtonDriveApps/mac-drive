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
    func start(onNodeRefreshed: @MainActor @escaping (Int) -> Void,
               onFinish: @MainActor () async throws -> Void,
               onCancel: @MainActor () -> Void,
               onError: @MainActor (Error) -> Void) async
    func cancel()
    func abort()
    var previousRunWasInterrupted: Bool { get }
}

final class FullResyncService: FullResyncServiceProtocol {
    
    typealias PersistentStoreInfos = (existing: PersistentStoreInfo, recovery: PersistentStoreInfo)
    
    enum ResyncState {
        case idle
        case eventsStopped
        case metadataRecoverySetup(metadata: (existing: PersistentStoreInfo, recovery: PersistentStoreInfo?))
        case eventRecoverySetup(metadata: PersistentStoreInfos, events: (existing: PersistentStoreInfo, recovery: PersistentStoreInfo?))
        case refreshFinished(metadata: PersistentStoreInfos, events: PersistentStoreInfos)
        case metadataReplacedWithRecovery(events: PersistentStoreInfos)
        case eventsReplacedWithRecovery
    }
    
    private var resyncState: ResyncState = .idle
    
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
        self.metadataStorage = metadataStorage
        self.syncStorage = syncStorage
        self.eventStorage = eventStorage
        self.cloudSlot = cloudSlot
        self.nodeRefresher = nodeRefresher
        self.startEvents = startEvents
        self.pauseEvents = pauseEvents
        self.clearAndReinitializeEvents = clearAndReinitializeEvents
    }
    
    func start(onNodeRefreshed: @MainActor @escaping (Int) -> Void,
               onFinish: @MainActor () async throws -> Void,
               onCancel: @MainActor () -> Void,
               onError: @MainActor (Error) -> Void) async {
        guard case .idle = resyncState else { return }

        do {
            cancelToken = CancelToken()
            
            // 0. Clear the old recovery and backup ones
            try performIfNotCancelled { cleanupLeftoversFromPreviousRecoveryAttempt() }
            
            // 1. Stop event loops
            try performIfNotCancelled { stopEvents() }
            
            // 2. Backup all DBs
            let metadata = try performIfNotCancelled { try setupMetadataRecovery() }
            let events = try performIfNotCancelled { try setupEventRecovery(metadata: metadata) }
            
            // 3. Bootstrap the new recovery DB
            let root = try await performIfNotCancelled { try await fetchRootFolder() }
            
            // 4. Perform the refresh
            try await performIfNotCancelled { try await performRefresh(metadata, events, root, onNodeRefreshed) }
            
            // Do not check the cancellation at this point — if we got to a refreshed state, just finish the operation
            
            // 5. Replace the old DBs with recovery DBs
            try metadataStorage.replaceExistingDBWithRecovery(existing: metadata.existing, recovery: metadata.recovery)
            resyncState = .metadataReplacedWithRecovery(events: events)
            
            try eventStorage.replaceExistingDBWithRecovery(existing: events.existing, recovery: events.recovery)
            resyncState = .eventsReplacedWithRecovery
            
            // 6. Start the event loop back
            try await clearAndReinitializeEvents()
            startEvents()
            
            resyncState = .idle
            
            try await onFinish()
        } catch {
            let wasCancelled = await handleError(error, resyncState)
            resyncState = .idle
            
            if wasCancelled {
                await onCancel()
            } else {
                Log.error("Full resync errored: \(error.localizedDescription)", domain: .application)
                await onError(error)
            }
        }
    }
    
    func cancel() {
        cancelToken?.cancel()
    }
    
    func abort() {
        resyncState = .idle
    }
    
    // MARK: - Private methods
    
    private func performIfNotCancelled<T>(_ block: () throws -> T) throws -> T {
        guard cancelToken?.isCancelled != true else {
            throw CocoaError(.userCancelled)
        }
        return try block()
    }
    
    private func performIfNotCancelled<T>(_ block: () async throws -> T) async throws -> T {
        guard cancelToken?.isCancelled != true else {
            throw CocoaError(.userCancelled)
        }
        return try await block()
    }
    
    private func cleanupLeftoversFromPreviousRecoveryAttempt() -> Bool {
        let metadataStorageExistedBefore = metadataStorage.cleanupLeftoversFromPreviousRecoveryAttempt()
        let eventStorageExistedBefore = eventStorage.cleanupLeftoversFromPreviousRecoveryAttempt()
        return metadataStorageExistedBefore || eventStorageExistedBefore
    }
    
    private func stopEvents() {
        pauseEvents()
        resyncState = .eventsStopped
    }
    
    private func setupMetadataRecovery() throws -> PersistentStoreInfos {
        let existingMetadata = try metadataStorage.disconnectExistingDB()
        resyncState = .metadataRecoverySetup(metadata: (existingMetadata, nil))
        let recoveryMetadata = try metadataStorage.createRecoveryDB(nextTo: existingMetadata)
        resyncState = .metadataRecoverySetup(metadata: (existingMetadata, recoveryMetadata))
        return (existingMetadata, recoveryMetadata)
    }
    
    private func setupEventRecovery(metadata: PersistentStoreInfos) throws -> PersistentStoreInfos {
        let existingEvents = try eventStorage.disconnectExistingDB()
        resyncState = .eventRecoverySetup(metadata: metadata, events: (existingEvents, nil))
        let recoveryEvents = try eventStorage.createRecoveryDB(nextTo: metadata.existing)
        resyncState = .eventRecoverySetup(metadata: metadata, events: (existingEvents, recoveryEvents))
        return (existingEvents, recoveryEvents)
    }
    
    private func fetchRootFolder() async throws -> Folder {
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
                                _ onNodeRefreshed: @MainActor @escaping (Int) -> Void) async throws {
        try await nodeRefresher.refreshUsingEagerSyncApproach(
            root: root, shouldIncludeDeletedItems: true, cancelToken: cancelToken, onNodeRefreshed: onNodeRefreshed
        )
        cancelToken = nil
        resyncState = .refreshFinished(metadata: metadata, events: events)
    }
    
    private func handleError(_ error: Error, _ resyncState: ResyncState) async -> Bool {
        switch resyncState {
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
        }
    }
}
