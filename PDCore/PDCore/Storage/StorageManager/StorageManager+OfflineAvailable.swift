// Copyright (c) 2026 Proton AG
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

import CoreData
import Foundation

/// Outcome of re-applying a resync snapshot's marked set to the rebuilt store. Counts only — safe to log.
public struct OfflineAvailableRestoreReport: Equatable, Sendable {
    /// Identifiers carried in the snapshot.
    public let requested: Int
    /// Matched in the rebuilt store and marked again.
    public let marked: Int
    /// Absent from the rebuilt store or deleted there, so skipped.
    public let missing: Int
    /// Descendants given `isInheritingOfflineAvailable`.
    public let inherited: Int

    public init(requested: Int, marked: Int, missing: Int, inherited: Int) {
        self.requested = requested
        self.marked = marked
        self.missing = missing
        self.inherited = inherited
    }
}

public extension StorageManager {

    private static let offlineAvailableMarkedChunkSize = 500
    private static let offlineAvailableChildrenChunkSize = 200
    private static let offlineAvailableChildrenFetchBatchSize = 1500

    /// Re-applies the marks a full resync captured before the metadata rebuild, then re-derives inheritance
    /// by walking down from every re-marked folder. Deriving from the rebuilt tree also covers nodes created
    /// or moved under a marked folder since the snapshot was taken.
    ///
    /// The rebuilt store is authoritative about state, so this is the only place the flow filters on it: a
    /// marked node it no longer has, or has in `.deleted` state, is counted as missing.
    ///
    /// Each chunk is a separate `perform`, so `moc`'s queue is released between them and the walk can be
    /// cancelled part-way — it runs ahead of the domain reconnection, where a large subtree would otherwise
    /// hold both.
    func restoreMarkedOfflineAvailable(
        _ identifiers: [NodeIdentifier],
        moc: NSManagedObjectContext
    ) async throws -> OfflineAvailableRestoreReport {
        guard !identifiers.isEmpty else {
            return OfflineAvailableRestoreReport(requested: 0, marked: 0, missing: 0, inherited: 0)
        }

        let requested = Set(identifiers)
        var visited = Set<NSManagedObjectID>()
        var frontier = Set<NSManagedObjectID>()
        var matched = Set<NodeIdentifier>()
        var inherited = 0

        // Distinct node ids: the same id in two chunks would fetch, re-mark and count the same rows twice.
        let idsToMark = Array(Set(requested.map(\.nodeID)))
        for chunk in idsToMark.splitInGroups(of: Self.offlineAvailableMarkedChunkSize) {
            try Task.checkCancellation()
            let remarked = try await moc.perform { () -> (matched: [NodeIdentifier], all: [NSManagedObjectID], folders: [NSManagedObjectID]) in
                let fetchRequest = NSFetchRequest<Node>()
                fetchRequest.entity = Node.entity()
                fetchRequest.predicate = NSPredicate(format: "%K IN %@", #keyPath(Node.id), chunk)
                fetchRequest.returnsObjectsAsFaults = false
                // Filtered by full identifier rather than fetched by shareID: the stored shareID column is
                // empty for SharedWithMe nodes, whose computed shareId derives one.
                let nodes = try moc.fetch(fetchRequest).filter {
                    requested.contains($0.identifierWithinManagedObjectContext) && $0.state != .deleted
                }
                for node in nodes {
                    node.isMarkedOfflineAvailable = true
                    node.isInheritingOfflineAvailable = false
                }
                // Persist before releasing: refreshing an object with pending changes would drop them.
                try moc.saveOrRollback()
                let matchedHere = nodes.map(\.identifierWithinManagedObjectContext)
                let all = nodes.map(\.objectID)
                let folders = nodes.compactMap { $0 is Folder ? $0.objectID : nil }
                // Back to faults so peak memory tracks a chunk, not the whole subtree; only ids travel on.
                nodes.forEach { moc.refresh($0, mergeChanges: false) }
                return (matchedHere, all, folders)
            }
            // Counted as identifiers covered, not rows re-marked, so duplicate rows for one identifier cannot
            // push `marked` above `requested` and `missing` below zero.
            matched.formUnion(remarked.matched)
            visited.formUnion(remarked.all)
            frontier.formUnion(remarked.folders)
        }

        while !frontier.isEmpty {
            // One snapshot per level. A `Set` frontier plus a to-one parentLink means two parents in the same
            // level cannot share a child, so chunks within a level need no dedup against each other.
            let alreadyVisited = visited
            var nextFrontier = Set<NSManagedObjectID>()
            for chunk in Array(frontier).splitInGroups(of: Self.offlineAvailableChildrenChunkSize) {
                try Task.checkCancellation()
                let level = try await moc.perform { () -> (touched: [NSManagedObjectID], folders: [NSManagedObjectID], inherited: Int) in
                    let fetchRequest = NSFetchRequest<Node>()
                    fetchRequest.entity = Node.entity()
                    fetchRequest.predicate = NSPredicate(format: "%K IN %@ AND %K != %d",
                                                         #keyPath(Node.parentLink), chunk.map { moc.object(with: $0) },
                                                         #keyPath(Node.stateRaw), Node.State.deleted.rawValue)
                    fetchRequest.fetchBatchSize = Self.offlineAvailableChildrenFetchBatchSize
                    fetchRequest.returnsObjectsAsFaults = false
                    var touched: [NSManagedObjectID] = []
                    var folders: [NSManagedObjectID] = []
                    var inheritedHere = 0
                    // One pass over the batched result: re-iterating it would re-fault every batch.
                    for child in try moc.fetch(fetchRequest) {
                        // Skipping the already-visited also breaks a parent cycle.
                        guard !alreadyVisited.contains(child.objectID) else { continue }
                        touched.append(child.objectID)
                        if !child.isMarkedOfflineAvailable {
                            child.setIsInheritingOfflineAvailable(true)
                            // The setter no-ops on a non-downloadable node, hence the read-back.
                            if child.isInheritingOfflineAvailable {
                                inheritedHere += 1
                            }
                        }
                        if child is Folder {
                            folders.append(child.objectID)
                        }
                    }
                    try moc.saveOrRollback()
                    touched.forEach { moc.refresh(moc.object(with: $0), mergeChanges: false) }
                    return (touched, folders, inheritedHere)
                }
                visited.formUnion(level.touched)
                inherited += level.inherited
                nextFrontier.formUnion(level.folders)
            }
            frontier = nextFrontier
        }

        return OfflineAvailableRestoreReport(
            requested: requested.count,
            marked: matched.count,
            missing: requested.count - matched.count,
            inherited: inherited
        )
    }
}
