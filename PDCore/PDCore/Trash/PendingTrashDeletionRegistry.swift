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

import Combine
import CoreData
import Foundation
import ProtonCoreUtilities

// Node.isToBeDeleted is a transient Core Data attribute: it is per-context and
// cleared on cross-context merges (see HasTransientValues). iOS trash screens
// read nodes from background contexts while delete writers may run on main, so
// we track optimistically hidden trash items in this in-memory registry instead.
public protocol PendingTrashDeletionRegistryProtocol: AnyObject {
    var changes: AnyPublisher<Void, Never> { get }
    func contains(_ identifier: AnyVolumeIdentifier) -> Bool
    func mark(_ identifiers: Set<AnyVolumeIdentifier>)
    func markRecursivelyWithinContext(nodes: [CoreDataNode])
    func removeAll()
}

@available(iOS 16, *)
public final class PendingTrashDeletionRegistry: PendingTrashDeletionRegistryProtocol {
    private var pendingIDs: Atomic<Set<AnyVolumeIdentifier>> = .init([])
    private let changeSubject = PassthroughSubject<Void, Never>()

    public init() {}

    public var changes: AnyPublisher<Void, Never> {
        changeSubject.eraseToAnyPublisher()
    }

    public func contains(_ identifier: AnyVolumeIdentifier) -> Bool {
        pendingIDs.transform { $0.contains(identifier) }
    }

    public func mark(_ identifiers: Set<AnyVolumeIdentifier>) {
        if identifiers.isEmpty { return }
        pendingIDs.mutate { $0.formUnion(identifiers) }
        changeSubject.send(())
    }

    public func markRecursivelyWithinContext(nodes: [CoreDataNode]) {
        var identifiers = Set<AnyVolumeIdentifier>()
        nodes.forEach { Self.collectIdentifiers(from: $0, into: &identifiers) }
        mark(identifiers)
    }

    public func removeAll() {
        pendingIDs.mutate { $0.removeAll() }
        changeSubject.send(())
    }

    private static func collectIdentifiers(from node: Node, into identifiers: inout Set<AnyVolumeIdentifier>) {
        identifiers.insert(node.genericIdentifierWithinManagedObjectContext)
        if node.isFolder, let folder = node as? Folder {
            folder.children.forEach { collectIdentifiers(from: $0, into: &identifiers) }
        }
    }
}

@available(iOS 16, *)
public extension PendingTrashDeletionRegistryProtocol {
    func markRecursively(identifiers: Set<AnyVolumeIdentifier>, storage: StorageManager) async {
        let context = storage.backgroundContext
        await context.perform { [self] in
            let nodes = Node.fetch(identifiers: identifiers, allowSubclasses: true, in: context)
            markRecursivelyWithinContext(nodes: nodes)
        }
    }

    func markRecursively(nodeIdentifiers: [NodeIdentifier], storage: StorageManager) async {
        await markRecursively(identifiers: Set(nodeIdentifiers.map { $0.any() }), storage: storage)
    }
}
