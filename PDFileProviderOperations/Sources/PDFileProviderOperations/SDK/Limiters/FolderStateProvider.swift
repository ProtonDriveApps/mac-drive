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
@preconcurrency import PDCore

/// Reason a folder was rejected by the backend.
public enum FolderLimitReason: Sendable {
    case tooManyChildren
    case nestingTooDeep
}

/// Reads the single folder property tied to a `FolderLimitReason` from local state.
public protocol FolderStateProvider: Sendable {
    func childrenCount(for folder: NodeIdentifier, in moc: NSManagedObjectContext) async -> Int?
    func depth(for folder: NodeIdentifier, in moc: NSManagedObjectContext) async -> Int?
}

public final class CoreDataFolderStateProvider: FolderStateProvider {
    public init() {}

    public func childrenCount(for folder: NodeIdentifier, in moc: NSManagedObjectContext) async -> Int? {
        await moc.perform {
            let fetchRequest = NSFetchRequest<Node>(entityName: "Node")
            fetchRequest.predicate = NSPredicate(format: "parentLink.id == %@", folder.nodeID)
            return try? moc.count(for: fetchRequest)
        }
    }

    public func depth(for folder: NodeIdentifier, in moc: NSManagedObjectContext) async -> Int? {
        await moc.perform {
            let fetchRequest = NSFetchRequest<Node>(entityName: "Node")
            fetchRequest.predicate = NSPredicate(format: "id == %@", folder.nodeID)
            fetchRequest.fetchLimit = 1
            fetchRequest.relationshipKeyPathsForPrefetching = ["parentLink"]
            guard let root = try? moc.fetch(fetchRequest).first else { return nil }
            var visited: Set<NSManagedObjectID> = [root.objectID]
            var depth = 0
            var node: Node? = root
            while let parent = node?.parentLink {
                guard visited.insert(parent.objectID).inserted else { return depth }
                depth += 1
                node = parent
            }
            return depth
        }
    }
}
