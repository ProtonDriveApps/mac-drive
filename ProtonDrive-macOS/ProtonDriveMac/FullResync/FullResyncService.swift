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
import CoreData

protocol FullResyncServiceProtocol {
    func start(resume: Bool,
               onScanStarted: @MainActor (_ scanEngineVersion: ScanEngineVersion) -> Void,
               onNodesRefreshed: @MainActor @escaping (_ saved: Int, _ total: Int?) -> Void,
               onDoneResyncing: @MainActor (RefreshedNodesReport) async throws -> Void,
               onCompleted: @MainActor () async throws -> Void,
               onCancelled: @MainActor () -> Void,
               onPaused: @MainActor @escaping () -> Void,
               onErrored: @MainActor (Error) -> Void) async
    func cancel(preservingRecovery: Bool)
    @discardableResult func pause() -> Bool
    func discardPreservedRecovery()
    var previousRunWasInterrupted: Bool { get }
    var metadataStorage: RecoverableStorage { get }
    var resolvedScanEngineVersion: ScanEngineVersion { get }
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

    private let fetchRoot: (NSManagedObjectContext) async throws -> (root: Folder, volumeID: String)
    let metadataStorage: RecoverableStorage
    private let syncStorage: RecoverableStorage?
    private let eventStorage: RecoverableStorage
    private let nodeRefresher: RefreshingNodesServiceProtocol
    private let startEvents: () -> Void
    private let pauseEvents: () -> Void
    private let captureEventCursor: () async throws -> (id: EventID, date: Date)
    private let clearAndReinitializeEvents: (_ referenceID: EventID, _ referenceDate: Date) async throws -> Void
    /// Deletes the v2 scan work-queue store, kept in lockstep with the recovery DB: dropped together on a
    /// discarding cancel, preserved together on a pause / recovery-preserving cancel / resumable error.
    private let discardResyncMetadataRepository: () -> Void
    private var capturedEventCursor: (id: EventID, date: Date)?
    private var cancelToken: CancelToken?

    /// Distinguishes a pause (recovery preserved, resumable) from a cancel (recovery discarded) —
    /// both surface as the same `userCancelled` error.
    private enum StopReason { case none, cancel, cancelPreservingRecovery, pause }
    private var stopReason: StopReason = .none

    var previousRunWasInterrupted: Bool {
        metadataStorage.previousRunWasInterrupted
    }

    var resolvedScanEngineVersion: ScanEngineVersion {
        nodeRefresher.resolvedScanEngineVersion()
    }
    
    private let moc: NSManagedObjectContext

    convenience init(tower: Tower) {
        self.init(
            metadataStorage: tower.storage,
            syncStorage: tower.syncStorage,
            eventStorage: tower.eventStorageManager,
            fetchRoot: { [weak tower] moc in
                guard let tower else {
                    throw NSError(domain: "me.proton.drive.fullResyncService", code: 1,
                                  localizedDescription: "Tower deallocated during root folder fetch")
                }
                guard let share = try await tower.cloudSlot.scanRootsAsync(isPhotosEnabled: false, moc: moc) else {
                    throw NSError(domain: "me.proton.drive.fullResyncService", code: 4,
                                  localizedDescription: "No main share found")
                }
                guard let root = await moc.perform({ share.root as? Folder }) else {
                    throw NSError(domain: "me.proton.drive.fullResyncService", code: 5,
                                  localizedDescription: "No root folder found")
                }
                // An empty volumeID would make every v2 volume-scoped endpoint fail; surface it instead.
                let volumeID = try await moc.perform {
                    let volumeID = share.volumeID
                    guard !volumeID.isEmpty else {
                        throw NSError(domain: "me.proton.drive.fullResyncService", code: 6,
                                      localizedDescription: "Main share has no volume ID")
                    }
                    return volumeID
                }
                return (root, volumeID)
            },
            nodeRefresher: tower.refresher,
            moc: tower.storage.backgroundContext,
            startEvents: { [weak tower] in tower?.runEventsSystem() },
            pauseEvents: { [weak tower] in tower?.pauseEventsSystem() },
            captureEventCursor: { [weak tower] in
                guard let tower else {
                    throw NSError(domain: "me.proton.drive.fullResyncService", code: 2,
                                  localizedDescription: "Tower deallocated during event cursor capture")
                }
                return try await tower.captureMainVolumeEventCursorForFullResync()
            },
            clearAndReinitializeEvents: { [weak tower] referenceID, referenceDate in
                await tower?.cleanUpEventsAndMetadata(cleanupStrategy: .cleanEvents)
                try tower?.intializeEventsDuringFullResync(referenceID: referenceID, referenceDate: referenceDate)
            },
            discardResyncMetadataRepository: { [weak tower] in tower?.discardResyncMetadataRepository() }
        )
    }
    
    init(metadataStorage: RecoverableStorage,
         syncStorage: RecoverableStorage?,
         eventStorage: RecoverableStorage,
         fetchRoot: @escaping (NSManagedObjectContext) async throws -> (root: Folder, volumeID: String),
         nodeRefresher: RefreshingNodesServiceProtocol,
         moc: NSManagedObjectContext,
         startEvents: @escaping () -> Void,
         pauseEvents: @escaping () -> Void,
         captureEventCursor: @escaping () async throws -> (id: EventID, date: Date),
         clearAndReinitializeEvents: @escaping (_ referenceID: EventID, _ referenceDate: Date) async throws -> Void,
         discardResyncMetadataRepository: @escaping () -> Void) {
        Log.trace()
        self.moc = moc
        self.metadataStorage = metadataStorage
        self.syncStorage = syncStorage
        self.eventStorage = eventStorage
        self.fetchRoot = fetchRoot
        self.nodeRefresher = nodeRefresher
        self.startEvents = startEvents
        self.pauseEvents = pauseEvents
        self.captureEventCursor = captureEventCursor
        self.clearAndReinitializeEvents = clearAndReinitializeEvents
        self.discardResyncMetadataRepository = discardResyncMetadataRepository
    }

    func start(resume: Bool = false,
               onScanStarted: @MainActor (_ scanEngineVersion: ScanEngineVersion) -> Void,
               onNodesRefreshed: @MainActor @escaping (_ saved: Int, _ total: Int?) -> Void,
               onDoneResyncing: @MainActor (RefreshedNodesReport) async throws -> Void,
               onCompleted: @MainActor () async throws -> Void,
               onCancelled: @MainActor () -> Void,
               onPaused: @MainActor @escaping () -> Void,
               onErrored: @MainActor (Error) -> Void
    ) async {
        guard case .idle = resyncStage else { return }
        stopReason = .none
        defer { capturedEventCursor = nil }

        Log.trace()
        do {
            cancelToken = CancelToken()

            // 0. Clear old recovery/backup DBs, unless resuming — then the preserved recovery DB must
            // survive so createRecoveryDB reopens it where the scan stopped.
            if !resume {
                try await performIfNotCancelled { _ = cleanupLeftoversFromPreviousRecoveryAttempt() }
            }

            // 1. Stop event loops
            try await performIfNotCancelled { stopEvents() }

            // Tell the UI the resync is now cancellable, so it can show Pause/Cancel. Before this point
            // they'd be no-ops, since the stage is still .idle. The variant picks the step list (v1/v2).
            await onScanStarted(nodeRefresher.resolvedScanEngineVersion())

            // 1.5 Capture the event cursor before any metadata is fetched, so events generated during the
            // refresh are replayed afterwards instead of silently skipped. Offline here aborts before any
            // DB change (stage is .eventsStopped → handleError restarts events).
            let cursor = try await performIfNotCancelled { try await captureEventCursor() }
            capturedEventCursor = cursor

            // 2. Backup all DBs — mark recovery in progress so the extension doesn't delete our files
            RecoveryCoordination.setInProgress()
            let metadata = try await performIfNotCancelled { try setupMetadataRecovery() }
            let events = try await performIfNotCancelled { try setupEventRecovery(metadata: metadata) }

            // 3. Bootstrap the new recovery DB
            let (root, volumeID) = try await performIfNotCancelled { try await fetchRoot(moc) }

            // 4. Perform the refresh
            let refreshedNodesReport = try await performIfNotCancelled {
                try await performRefresh(metadata, events, root, volumeID: volumeID, resume: resume, onNodesRefreshed)
            }

            // The DB swap below is irreversible, and a fast scan can finish before cancelToken.cancel()
            // lands. Check stopReason directly so a late pause/cancel still takes effect here.
            guard stopReason == .none else { throw CocoaError(.userCancelled) }

            // 5. Replace the old DBs with recovery DBs
            try metadataStorage.replaceExistingDBWithRecovery(existing: metadata.existing, recovery: metadata.recovery)
            // Signal the extension to reload as soon as the metadata DB is physically swapped, so it picks up
            // the new store even if the event-store replacement below fails (otherwise it serves stale metadata).
            RecoveryCoordination.markStoreReplaced()
            resyncStage = .metadataReplacedWithRecovery(events: events)

            try eventStorage.replaceExistingDBWithRecovery(existing: events.existing, recovery: events.recovery)
            resyncStage = .eventsReplacedWithRecovery
            // markStoreReplaced already ran, so the extension never observes a window with neither flag set.
            RecoveryCoordination.clearInProgress()
            
            // 6. Enumerate
            resyncStage = .enumeratingAfterResync

            // 7. Reinitialize the events loop with the cursor captured before the snapshot
            try await clearAndReinitializeEvents(cursor.id, cursor.date)

            // 8. Trigger enumeration and wait for it to complete
            try await onDoneResyncing(refreshedNodesReport)
            
            // 9. Restart the events loop after enumeration finishes
            startEvents()

            // 10. Mark resync operation as completed
            resyncStage = .idle
            try await onCompleted()
        } catch {
            RecoveryCoordination.clearInProgress()
            // A pause or recovery-preserving cancel keeps the recovery DBs (so the run can resume); a plain
            // user cancel discards them. A genuine failure keeps them — including an ambient cancellation with
            // no stop reason, now treated as a failure — so Retry can re-attempt.
            let isCancellation = isUserCancellation(error)
            let discardRecovery = isCancellation && stopReason != .pause && stopReason != .cancelPreservingRecovery
            let wasCancelled = await handleError(error, resyncStage, discardRecovery: discardRecovery)
            // handleError already discarded the recovery DB and reconnected the existing stores; drop the scan
            // work-queue store to stay in lockstep (not discardPreservedRecovery, which re-cleans those stores).
            if discardRecovery { discardResyncMetadataRepository() }
            resyncStage = .idle

            // `handleError` is a suspension point, so a Cancel tapped during the wind-down changes
            // `stopReason` after `discardRecovery` was computed. Re-evaluate: a run that ends up cancelled
            // must not leave the recovery DB and work queue behind, or the next launch sees
            // previousRunWasInterrupted and offers to resume a run the user explicitly cancelled.
            let shouldDiscardAfterLateStop = isCancellation && stopReason != .pause && stopReason != .cancelPreservingRecovery
            if shouldDiscardAfterLateStop, !discardRecovery {
                Log.info("Discarding preserved recovery: the resync was cancelled during its wind-down", domain: .resyncing)
                discardPreservedRecovery()
            }

            if stopReason == .pause {
                await onPaused()
            } else if wasCancelled {
                await onCancelled()
            } else {
                Log.error("Full resync errored: \(error.localizedDescription)", domain: .resyncing)
                await onErrored(error)
            }
        }
    }
    
    func cancel(preservingRecovery: Bool = false) {
        stopReason = preservingRecovery ? .cancelPreservingRecovery : .cancel
        cancelToken?.cancel()

        if resyncStage.isCancellable {
            // Before a certain stage, we mark the resync as cancelled, and subsequent steps will be skipped due to a userCancelled error being thrown.
            Log.trace("cancel")
        } else {
            // The scan already finished, so leave Resync mode directly. Discard any preserved recovery DB
            // unless the caller asked to keep it — otherwise the next launch would detect it and auto-resume.
            Log.trace("abort")
            resyncStage = .idle
            if !preservingRecovery {
                discardPreservedRecovery()
            }
        }
    }

    /// Pauses an in-progress scan, preserving the recovery DB so it can be resumed. No-op outside the
    /// cancellable phase. Returns whether the pause was accepted, so the caller can avoid showing a paused
    /// UI for a resync that is going to run to completion regardless.
    @discardableResult
    func pause() -> Bool {
        guard resyncStage.isCancellable else { return false }
        Log.trace("pause")
        stopReason = .pause
        cancelToken?.cancel()
        return true
    }

    /// Discards a recovery DB preserved by a pause or error, so a subsequent start rebuilds from scratch.
    func discardPreservedRecovery() {
        Log.trace()
        _ = cleanupLeftoversFromPreviousRecoveryAttempt()
        discardResyncMetadataRepository()
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
    
    enum FullResyncError: LocalizedError {
        case completedWithFailures(count: Int)
        var errorDescription: String? {
            switch self {
            case .completedWithFailures(let count):
                return "Full resync completed with \(count) unresolved item(s) after retries"
            }
        }
    }

    private func performRefresh(_ metadata: FullResyncService.PersistentStoreInfos,
                                _ events: FullResyncService.PersistentStoreInfos,
                                _ root: Folder,
                                volumeID: String,
                                resume: Bool,
                                _ onNodesRefreshed: @MainActor @escaping (_ saved: Int, _ total: Int?) -> Void) async throws -> RefreshedNodesReport {
        Log.trace()
        let refreshedNodesReport = try await nodeRefresher.refreshUsingSyncApproach(
            root: root, volumeID: volumeID, resume: resume, cancelToken: cancelToken, onNodesRefreshed: onNodesRefreshed
        )
        cancelToken = nil
        // Abandoned items mean the scanned tree is incomplete, so don't swap it in. Throwing here preserves
        // the recovery DB and the work queue (it isn't a cancellation), so Retry resumes and re-attempts them.
        guard refreshedNodesReport.failed == 0 else {
            throw FullResyncError.completedWithFailures(count: refreshedNodesReport.failed)
        }
        resyncStage = .refreshFinished(metadata: metadata, events: events)
        return refreshedNodesReport
    }
    
    /// Distinguishes a user-initiated stop from a genuine failure. `CocoaError.userCancelled` is a deliberate
    /// signal our own code throws (a late cancel checked after the scan finished, or the `performIfNotCancelled`
    /// pre-check), so it always counts as a user action. `CancellationError` (the scan engine's task cancelled
    /// mid-scan) and `URLError.cancelled` (a V2 in-flight request cancelled) are ambient — URLSession also emits
    /// `.cancelled` for aborts we didn't initiate (session invalidation, auth-layer/interceptor teardown) — so
    /// they count only when the service actually recorded a stop (`stopReason != .none`); otherwise they are failures.
    private func isUserCancellation(_ error: Error) -> Bool {
        if (error as? CocoaError)?.code == .userCancelled { return true }
        guard stopReason != .none else { return false }
        return error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func handleError(_ error: Error, _ resyncStage: FullResyncStage, discardRecovery: Bool) async -> Bool {
        Log.trace("\(resyncStage)")
        switch resyncStage {
        case .idle:
            return isUserCancellation(error)
        case .eventsStopped:
            startEvents()
            return await handleError(error, .idle, discardRecovery: discardRecovery)
        case let .metadataRecoverySetup(metadata: (existing, recovery)):
            do {
                try metadataStorage.reconnectExistingDBAndDiscardRecoveryIfNeeded(existing: existing, recovery: recovery, discardRecovery: discardRecovery)
            } catch {
                metadataStorage.cleanupLeftoversFromPreviousRecoveryAttempt()
            }
            return await handleError(error, .eventsStopped, discardRecovery: discardRecovery)
        case let .eventRecoverySetup((metadataExisting, metadataRecovery), (eventsExisting, eventsRecovery)):
            do {
                try eventStorage.reconnectExistingDBAndDiscardRecoveryIfNeeded(existing: eventsExisting,
                                                                               recovery: eventsRecovery,
                                                                               discardRecovery: discardRecovery)
            } catch {
                eventStorage.cleanupLeftoversFromPreviousRecoveryAttempt()
            }
            return await handleError(error, .metadataRecoverySetup(metadata: (metadataExisting, metadataRecovery)), discardRecovery: discardRecovery)
        case let .refreshFinished(metadata, events):
            // error here means we tried to replace existing DB with recovery, but we failed. Let's revert the whole operation
            return await handleError(error, .eventRecoverySetup(metadata: metadata, events: events), discardRecovery: discardRecovery)
        case .metadataReplacedWithRecovery:
            // Error here means we managed to replace existing DB with recovery, but we failed to do the same for events.
            // We will try clearing the events and restarting them.
            return await handleError(error, .eventsReplacedWithRecovery, discardRecovery: discardRecovery)
        case .eventsReplacedWithRecovery, .enumeratingAfterResync:
            // DBs are already replaced; whatever failed, the event loop must end up running again. On the
            // .enumeratingAfterResync path the loop was reinitialized but startEvents() is deferred until after
            // enumeration, so a failure there would otherwise leave events permanently stopped until next launch.
            do {
                guard let cursor = capturedEventCursor else {
                    throw NSError(domain: "me.proton.drive.fullResyncService", code: 3,
                                  localizedDescription: "Missing captured event cursor during events reinitialization")
                }
                try await clearAndReinitializeEvents(cursor.id, cursor.date)
                startEvents()
            } catch {
                // There is no good path from here. Initialization of events failed. The event loop will not work.
                // It will start working on the next app start though. Log and continue rather than crash.
                Log.error("Events loop reinitialization failed", error: error, domain: .events)
            }
            return await handleError(error, .idle, discardRecovery: discardRecovery)
        }
    }
}
