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
import PDClient
import FileProvider

protocol DriveEventsLoopProcessorType {
    func process() async throws -> [NodeIdentifier]
}

final class DriveEventsLoopProcessor: DriveEventsLoopProcessorType {

    private let volumeID: String
    private let cloudSlot: CloudSlotProtocol
    private let conveyor: EventsConveyor
    private let storage: StorageManager
    private let myPhotoVolumeID: String?

    internal init(
        volumeID: String,
        cloudSlot: CloudSlotProtocol,
        conveyor: EventsConveyor,
        storage: StorageManager
    ) {
        self.volumeID = volumeID
        self.cloudSlot = cloudSlot
        self.conveyor = conveyor
        self.storage = storage
        myPhotoVolumeID = storage.getPhotosVolumeId(in: storage.backgroundContext)
    }

    // The assumption is that all the metadata DB Nodes are separate between the volumes.
    // There is no CoreData relationship between any node in one volume and a node in another volume,
    // so there's no need to use a single context for multiple loops / processors.

    func process() async throws -> [NodeIdentifier] {
        Log.event(.eventLoopProcess(.started(.init(loopType: .drive, volumeID: self.volumeID))))
        
        let affectedNodes: [NodeIdentifier]
        do {
            affectedNodes = try await storage.backgroundContextPool.performInContext { moc in
                var affectedNodes: [NodeIdentifier] = []
                try self.applyEventsToStorage(&affectedNodes, in: moc)
                
                if moc.hasChanges {
                    try moc.saveOrRollback()
                }
                return affectedNodes
            }
            Log.event(.eventLoopProcess(.succeeded(.init(loopType: .drive, count: affectedNodes.count, volumeID: volumeID))))
        } catch {
            Log.event(.eventLoopProcess(.failed(.init(id: volumeID, error: error))))
            throw error
        }
        return affectedNodes
    }
    
    private func applyEventsToStorage(_ affectedNodes: inout [NodeIdentifier],
                                      in moc: NSManagedObjectContext) throws {
        
        func updateMetadata(_ shareID: String, _ event: Event) {
            let updated = self.update(shareId: shareID, from: event, in: moc)
            affectedNodes.append(contentsOf: updated)
            Log.event(.eventProcess(.succeeded(.init(eventID: event.eventId, eventType: .init(eventType: event.genericType), nodeID: event.inLaneNodeId, volumeID: volumeID, shareID: shareID, outcome: .applied))))
        }

        while let (event, shareID, objectID) = conveyor.next() {
            Log.event(.eventProcess(.started(.init(eventID: event.eventId, eventType: .init(eventType: event.genericType), nodeID: event.inLaneNodeId, volumeID: event.volumeId, shareID: shareID))))
            Log.debug("Start to handle event \(event.eventId)", domain: .events)
            guard let event = event as? Event else {
                ignored(event: event, storage: storage)
                Log.event(.eventProcess(.succeeded(.init(eventID: event.eventId, eventType: .init(eventType: event.genericType), nodeID: event.inLaneNodeId, volumeID: volumeID, shareID: shareID, outcome: .ignored))))
                conveyor.completeProcessing(of: objectID)
                continue
            }

            let nodeID = event.inLaneNodeId
            let volumeID = event.link.volumeID
            let nodeIdentifier = NodeIdentifier(nodeID, shareID, volumeID)
            let parentIdentifier = makeNodeIdentifier(volumeID: volumeID, shareID: shareID, nodeID: event.inLaneParentId)

            var linkType: String = "Unknown"
            switch event.link.type {
            case .file:
                if event.link.fileProperties?.activeRevision?.photo == nil {
                    linkType = "File"
                } else {
                    linkType = "Photo"
                }
            default:
                linkType = event.link.type.desc
            }

            switch event.genericType {
            case .create:
                // case 1. — node already exists in the DB
                if let node = findNode(id: nodeIdentifier, in: moc) {
                    let state = moc.performAndWait { node.state }
                    if event.link.state.rawValue == state?.rawValue {
                        // Fix for DM-387 & DM-398
                        conveyor.disregard(objectID)
                        Log.event(.eventProcess(.succeeded(.init(eventID: event.eventId, eventType: .init(eventType: event.genericType), nodeID: event.inLaneNodeId, volumeID: volumeID, shareID: shareID, outcome: .disregarded))))
                    } else {
                        updateMetadata(shareID, event)
                    }
                } else if nodeExists(id: parentIdentifier, in: moc) {
                    // case 2. — node doesn't yet exists in the DB, but its parent exists, so we can create the node
                    updateMetadata(shareID, event)
                } else if linkType == "Photo" && myPhotoVolumeID != volumeID {
                    // Events from shared volume
                    updateMetadata(shareID, event)
                } else {
                    ignored(event: event, storage: storage)
                    Log.event(.eventProcess(.succeeded(.init(eventID: event.eventId, eventType: .init(eventType: event.genericType), nodeID: event.inLaneNodeId, volumeID: volumeID, shareID: shareID, outcome: .ignored))))
                }

            case .updateMetadata where nodeExists(id: parentIdentifier, in: moc) || nodeExists(id: nodeIdentifier, in: moc), // need to know node (move from) or the new parent (move to)
                 .delete,
                 .updateContent where nodeExists(id: nodeIdentifier, in: moc): // need to know node
                updateMetadata(shareID, event)

            default: // ignore event
                ignored(event: event, storage: storage)
                Log.event(.eventProcess(.succeeded(.init(eventID: event.eventId, eventType: .init(eventType: event.genericType), nodeID: event.inLaneNodeId, volumeID: volumeID, shareID: shareID, outcome: .ignored))))
            }

            conveyor.completeProcessing(of: objectID)
        }
    }
}

extension DriveEventsLoopProcessor {

    private func makeNodeIdentifier(volumeID: String, shareID: String, nodeID: String?) -> NodeIdentifier? {
        guard let nodeID else { return nil }
        return NodeIdentifier(nodeID, shareID, volumeID)
    }

    private func update(shareId: String, from event: GenericEvent, in moc: NSManagedObjectContext) -> [NodeIdentifier] {
        guard let event = event as? Event else {
            assert(false, "Wrong event type sent to \(#file)")
            return []
        }
        let identifier = NodeIdentifier(event.link.linkID, shareId, event.link.volumeID)

        switch event.eventType {
        case .delete:
            guard let node = findNode(id: identifier, in: moc) else {
                Log.info("Processing delete event. Node: \(identifier.any()) not found", domain: .events)
                return []
            }
            moc.delete(node)
            return [node.identifier, node.parentNode?.identifier].compactMap { $0 }
            
        case .create, .updateMetadata:
            let nodes = cloudSlot.update([event.link], of: shareId, in: moc)

            var affectedNodes = nodes.compactMap(\.parentLink).map(\.identifier)
            affectedNodes.append(contentsOf: nodes.map(\.identifier))
            return affectedNodes
            
        case .updateContent:
            let identifier = NodeIdentifier(event.link.linkID, shareId, event.link.volumeID)
            guard let file = findFile(identifier: identifier, in: moc) else {
                Log.info("Processing .updateContent event. File: \(identifier.any()) not found", domain: .events)
                return []
            }
            if let revision = file.activeRevision, revision.id != event.link.fileProperties?.activeRevision?.ID {
                revision.removeOldThumbnails(in: moc)
                storage.removeOutdatedCache(of: revision)
                file.activeRevision = nil
                _ = cloudSlot.update([event.link], of: shareId, in: moc)
            }
            return [file.identifier]
        }
    }
    
    private func ignored(event: GenericEvent, storage: StorageManager) {
        // link may be shared or unshared - need to re-fetch Share URLs
        storage.finishedFetchingShareURLs = false
        
        // link may be trashed or untrashed - need to re-fetch Trash
        storage.finishedFetchingTrash = false
    }

}

extension DriveEventsLoopProcessor {
    private func findNode(
        id identifier: NodeIdentifier, by attribute: String = "id", in moc: NSManagedObjectContext
    ) -> Node? {
        if identifier.volumeID.isEmpty {
            let asFile: File? = storage.existing(with: [identifier.nodeID], by: attribute, allowSubclasses: true, in: moc).first
            let asFolder: Folder? = storage.existing(with: [identifier.nodeID], by: attribute, in: moc).first
            let asAlbum: CoreDataAlbum? = storage.existing(with: [identifier.nodeID], by: attribute, in: moc).first
            return asFolder ?? asFile ?? asAlbum
        } else {
            let asFile = File.fetch(identifier: identifier, allowSubclasses: true, in: moc)
            let asFolder = Folder.fetch(identifier: identifier, in: moc)
            let asAlbum = CoreDataAlbum.fetch(identifier: identifier, in: moc)
            return asFolder ?? asFile ?? asAlbum
        }
    }
    
    private func nodeExists(id identifier: NodeIdentifier?, in moc: NSManagedObjectContext) -> Bool {
        guard let identifier = identifier else { return false }
        if identifier.volumeID.isEmpty {
            return self.storage.exists(with: identifier.nodeID, by: #keyPath(Node.id), entityName: "Node", in: moc)
        } else {
            return Node.fetch(identifier: identifier, allowSubclasses: true, in: moc) != nil
        }
    }
    
    private func findFile(identifier: NodeIdentifier, in moc: NSManagedObjectContext) -> File? {
        if identifier.volumeID.isEmpty {
            let file: File? = storage.existing(with: [identifier.nodeID], in: moc).first
            return file
        } else {
            let file = File.fetch(identifier: identifier, allowSubclasses: true, in: moc)
            return file
        }
    }

    private func findAlbum(identifier: NodeIdentifier, in moc: NSManagedObjectContext) -> CoreDataAlbum? {
        CoreDataAlbum.fetch(identifier: identifier, in: moc)
    }

}
