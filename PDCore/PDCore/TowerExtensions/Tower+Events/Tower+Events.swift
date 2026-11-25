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

import Foundation
import CoreData
import PMEventsManager
import ProtonCoreServices

public protocol EventsTriggerController {
    func forcePolling(volumeIDs: [String])
}

public protocol EventsSystemManager: AnyObject, MainVolumeEventsReferenceProtocol, EventsTriggerController {
    // event scheduler
    func intializeEventsSystem(includeAllVolumes: Bool) throws
    func runEventsSystem()
    func pauseEventsSystem()

    // event loops
    func forcePolling(volumeIDs: [String])
    func forceProcessEvents() async
    var eventProcessorIsRunning: Bool { get }
    
    #if os(iOS)
    func removeSharedVolumesEventLoops(volumeIds: [String])
    func removeAllSharedVolumesEventLoops()
    #endif
}

public protocol MainVolumeEventsReferenceProtocol {
    typealias EventsHistoryRow = (event: GenericEvent, share: String, objectID: NSManagedObjectID)

    func lastEnumeratedEvent() -> GenericEvent?
    func lastUnenumeratedEvent() -> GenericEvent?
    func lastReceivedEvent() -> GenericEvent?
    func eventsHistory(since anchor: EventID?) throws -> [EventsHistoryRow]
    func setEnumerated(_ objectIDs: [NSManagedObjectID])

    var eventSystemReferenceDate: Date? { get }
    var eventSystemReferenceID: EventID? { get }
    var eventSystemLatestFetchTime: Date? { get }
}

extension Tower: EventsSystemManager {

    public func intializeEventsSystem(includeAllVolumes: Bool) throws {
        Log.trace()
        let moc = storage.backgroundContext
        let volumeIds = try self.storage.getVolumeIDs(in: moc)

        #if os(macOS)
        initializeSingleVolumeEventLoop(volumeId: volumeIds.main)
        #endif
    }

    #if os(macOS)
    /// Fetches the current head of the main volume's event stream. Called at the start of a full resync,
    /// before the metadata snapshot, so the post-resync replay starts from a point that precedes the snapshot.
    public func captureMainVolumeEventCursorForFullResync() async throws -> (id: EventID, date: Date) {
        Log.trace()
        let mainVolumeId = try self.storage.getVolumeIDs(in: storage.backgroundContext).main
        let eventID = try await cloudSlot.fetchInitialEvent(ofVolumeID: mainVolumeId)
        return (eventID, Date())
    }

    public func intializeEventsDuringFullResync(referenceID: EventID, referenceDate: Date) throws {
        Log.trace()
        let mainVolumeId = try self.storage.getVolumeIDs(in: storage.backgroundContext).main
        initializeSingleVolumeEventLoop(volumeId: mainVolumeId)
        // Apply the cursor captured before the snapshot rather than fetching the current latest event now,
        // which would skip events that occurred during the snapshot.
        mainVolumeEventsConveyor?.referenceID = referenceID
        mainVolumeEventsConveyor?.referenceDate = referenceDate
        mainVolumeEventsConveyor?.latestFetchedEventID = referenceID
        mainVolumeEventsConveyor?.latestEventFetchTime = referenceDate
    }

    /// Drops the events cursor and the queued events that outlive a sign-out. `destroyAnchors()` only
    /// covers enabled loops, so a Tower built after sign-out keeps the previous session's cursor and
    /// would poll the new volume from a foreign event ID.
    public func discardPersistedEventsState() {
        Self.discardPersistedEventsState(referenceStorage: LegacyEventsReferenceStorage(suite: storageSuite),
                                         eventStorageManager: eventStorageManager)
    }

    static func discardPersistedEventsState(referenceStorage: LegacyEventsReferenceStorage,
                                            eventStorageManager: EventStorageManager) {
        let discardedCursor = referenceStorage.latestFetchedEventID ?? "none"
        let discardedEvents = (try? eventStorageManager.unprocessedEventCount(volumeId: "")) ?? 0
        referenceStorage.clear()
        // Only the rows the legacy conveyor reads; ones carrying a real volume ID are left to
        // `periodicalCleanup`.
        eventStorageManager.clearUp(volumeId: "")
        Log.info("Discarded persisted events state (cursor: \(discardedCursor), queued events: \(discardedEvents))",
                 domain: .events)
    }

    private func initializeSingleVolumeEventLoop(volumeId: String) {
        Log.trace()
        let factory = EventsFactory()
        let legacyConveyor = factory.makeLegacyConveyor(tower: self)
        let loop = factory.makeEventsLoop(tower: self, conveyor: legacyConveyor, volumeId: volumeId)
        mainVolumeEventsConveyor = legacyConveyor
        coreEventManager.enable(loop: loop, for: volumeId)
    }
    #endif

    #if os(iOS)
    public func removeSharedVolumesEventLoops(volumeIds: [String]) {
        Log.info("Removing shared volumes loops: \(volumeIds)", domain: .events)
        volumeIdsController.removeSharedVolumes(ids: volumeIds)
        coreEventManager.removeLoops(with: volumeIds)
    }

    public func removeAllSharedVolumesEventLoops() {
        Log.info("Removing all shared volumes loops", domain: .events)
        let volumeIds = volumeIdsController.getVolumes().sharedVolumes.map(\.id)
        volumeIdsController.removeSharedVolumes(ids: volumeIds)
        coreEventManager.removeLoops(with: volumeIds)
    }
    #endif

    public func runEventsSystem() {
        guard isFetchEventsPossible() else {
            Log.trace("guard")
            return
        }
        Log.trace()
        coreEventManager.start()
    }

    private func isFetchEventsPossible() -> Bool {
        if Constants.buildType.isQaOrBelow {
            Log.trace("\(shouldFetchEvents != false)")
            return shouldFetchEvents != false
        } else {
            Log.trace("true")
            return true
        }
    }

    public var eventProcessorIsRunning: Bool {
        Log.trace()
        return coreEventManager.isRunning
    }
    
    public func pauseEventsSystem() {
        Log.trace()
        coreEventManager.suspend()
    }
    
    public func forceProcessEvents() async {
        Log.trace()
        guard !coreEventManager.currentlyEnabledLoops().isEmpty else {
            Log.error("No event loop(s) to process events", error: nil, domain: .events)
            return
        }

        await coreEventManager.currentlyEnabledLoops().asyncForEach { loop in
            try? await loop.performProcessing()
        }
    }

    public func forcePolling(volumeIDs: [String]) {
        if Thread.isMainThread {
            Log.trace()
            coreEventManager.forcePolling(volumeIDs: volumeIDs)
        } else {
            DispatchQueue.main.async {
                self.forcePolling(volumeIDs: volumeIDs)
            }
        }
    }

    // MARK: - MainVolumeEventsReferenceProtocol

    /// Disclaimer ⚠️
    /// `mainVolumeEventsConveyor` is created when events are initiated. The below code shouldn't be called before that.

    /// Event that was recorded into events storage and both applied to metadata storage and enumerated by the system. Will be `nil` if no events have been enumerated yet or if no events present
    public func lastEnumeratedEvent() -> GenericEvent? {
        mainVolumeEventsConveyor?.lastFullyHandledEvent()
    }
    
    /// Event that was recorded into events storage and applied to metadata storage, but not yet enumerated by the system. Will be `nil` if all events have been enumerated
    public func lastUnenumeratedEvent() -> GenericEvent? {
        mainVolumeEventsConveyor?.lastEventAwaitingEnumeration()
    }
    
    /// Event received from API and saved into events DB.  Will be `nil` if no events were fetched from BE since latest login or cache clearing
    public func lastReceivedEvent() -> GenericEvent? {
        mainVolumeEventsConveyor?.lastReceivedEvent()
    }
    
    public func eventsHistory(since anchor: EventID?) throws -> [EventsHistoryRow] {
        (try mainVolumeEventsConveyor?.history(since: anchor)) ?? []
    }
    
    public func setEnumerated(_ objectIDs: [NSManagedObjectID]) {
        mainVolumeEventsConveyor?.setEnumerated(objectIDs)
    }
    
    /// Moment when started tracking events (login or cache clearing caued by user or .refresh event). Will be `nil` before initial event ID of event system is recorded (during login or after cache nuking)
    public var eventSystemReferenceDate: Date? {
        mainVolumeEventsConveyor?.referenceDate
    }
    
    public var eventSystemReferenceID: EventID? {
        mainVolumeEventsConveyor?.referenceID
    }
    
    /// Latest date of successfull API request. Will be `nil` before initial event ID of event system is recorded (during login or after cache nuking)
    public var eventSystemLatestFetchTime: Date? {
        mainVolumeEventsConveyor?.latestEventFetchTime
    }
}

extension Tower {    
    /// Stop active polling and clears local storages used by the polling system.
    /// After calling this method polling needs to be re-started from scratch including fetch of initial event ID.
    static func discardEventsPolling(for coreEventManager: CoreEventLoopManager) {
        coreEventManager.suspend()
        coreEventManager.destroyAnchors()
        coreEventManager.reset()
    }
    
}
