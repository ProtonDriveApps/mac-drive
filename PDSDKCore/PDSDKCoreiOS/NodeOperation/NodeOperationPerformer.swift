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
import PDSDKCore
import PDCore
import ProtonDriveSDK

public final class NodeOperationPerformer: SDKNodeOperationPerformer {
    private let dependencies: Dependencies
    private var context: NSManagedObjectContext { dependencies.context }
    private let volumeBatchPerformerResolver = VolumeBatchPerformerResolver()

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    public func rename(nodeUid: AnyVolumeIdentifier, newName: String) async throws -> Node {
        let validatedName = try newName.validateNodeName(validator: NameValidations.iosName)
        let (node, isProtonFile) = try await context.perform { [context] in
            let node = try Node.fetch(identifier: nodeUid, allowSubclasses: true, in: context) ?! "Can't reterive node"
            let isProtonFile = (node as? File)?.isProtonFile ?? false
            return (node, isProtonFile)
        }

        let newMime: String?
        if node is Folder {
            newMime = Folder.mimeType
        } else if validatedName.fileExtension.isEmpty || isProtonFile {
            // Preserve the previous MIME type in case:
            // 1. The user removed it when renaming; or
            // 2. It's a Proton Document, which doesn't have an extension on other platforms
            newMime = nil
        } else {
            newMime = URL(fileURLWithPath: validatedName).mimeType()
        }

        try await dependencies.performer.rename(
            nodeUid: nodeUid.sdkUid,
            newName: validatedName,
            newMediaType: newMime,
            cancellationToken: UUID(),
            moc: context
        )
        return node
    }

    public func createFolder(parentFolderID: AnyVolumeIdentifier, name: String) async throws -> CoreDataFolder {
        let validatedName = try name.validateNodeName(validator: NameValidations.iosName)
        return try await dependencies.performer.createFolder(
            parentFolderUid: parentFolderID.sdkUid,
            folderName: validatedName,
            lastModificationTime: Date(),
            resolveConflictByRenaming: false,
            moc: dependencies.context,
            cancellationToken: UUID()
        )
    }
}

// MARK: - Device
extension NodeOperationPerformer {
    public func renameDevice(identifier: DeviceIdentifier, newName: String) async throws {
        try await dependencies.performer.renameDevice(
            identifier: identifier,
            newName: newName,
            cancellationToken: UUID(),
            moc: dependencies.context
        )
    }
}

extension NodeOperationPerformer {
    // The SDK groups nodes by volume ID, so file and photo nodes share one performer per operation type.
    public func trash(nodes: [AnyVolumeIdentifier]) -> AsyncThrowingStream<SDKNodeOperationStreamEvent, Error> {
        perVolumeNodeOperationStream(nodes: nodes, operation: .trash)
    }

    public func delete(nodes: [AnyVolumeIdentifier]) -> AsyncThrowingStream<SDKNodeOperationStreamEvent, Error> {
        perVolumeNodeOperationStream(nodes: nodes, operation: .delete)
    }

    public func restore(nodes: [AnyVolumeIdentifier]) -> AsyncThrowingStream<SDKNodeOperationStreamEvent, Error> {
        perVolumeNodeOperationStream(nodes: nodes, operation: .restore)
    }

    public func emptyTrash() async throws {
        let context = dependencies.context
        async let emptyFileTrash = dependencies.performer.emptyTrash(cancellationToken: UUID(), moc: context)
        async let emptyPhotoTrash = dependencies.photoPerformer.emptyTrash(cancellationToken: UUID(), moc: context)
        let _ = try await (emptyFileTrash, emptyPhotoTrash)
    }

    private func perVolumeNodeOperationStream(
        nodes: [AnyVolumeIdentifier],
        operation: NodeBatchOperation
    ) -> AsyncThrowingStream<SDKNodeOperationStreamEvent, Error> {
        if nodes.isEmpty {
            return AsyncThrowingStream { continuation in
                continuation.yield(.completed(error: nil))
                continuation.finish()
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let volumeIDs = try await dependencies.storage.getVolumeIDs(within: context)
                    let chunks = nodes.splitIntoChunksByVolume()
                    var firstError: Error?

                    for chunk in chunks {
                        let chunkNodes = chunk.nodeIds.map { AnyVolumeIdentifier(id: $0, volumeID: chunk.volumeId) }
                        let performer = await batchPerformer(for: chunk.volumeId, volumeIDs: volumeIDs)
                        let inner = performer.stream(
                            operation: operation,
                            nodes: chunkNodes,
                            cancellationToken: UUID(),
                            moc: context
                        )

                        for try await event in inner {
                            switch event {
                            case .nodeResults(let results, let affectedIdentifiers):
                                continuation.yield(
                                    .nodeResults(
                                        results: results.map { ($0.nodeUid.any, error: $0.error) },
                                        affectedIdentifiers: affectedIdentifiers
                                    )
                                )
                            case .completed(let error):
                                if firstError == nil {
                                    firstError = error
                                }
                            }
                        }
                    }

                    continuation.yield(.completed(error: firstError))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func batchPerformer(
        for volumeID: String,
        volumeIDs: StorageManager.VolumeIDs
    ) async -> any NodeBatchStreamPerforming {
        await volumeBatchPerformerResolver.performer(
            for: volumeID,
            volumeIDs: volumeIDs,
            filePerformer: dependencies.fileBatchPerformer,
            photoPerformer: dependencies.photoBatchPerformer,
            context: context
        )
    }
}

// MARK: - Sharing
extension NodeOperationPerformer {
    public func leaveSharedNode(nodeUid: AnyVolumeIdentifier) async throws {
        let volumeIDs = try await dependencies.storage.getVolumeIDs(within: context)
        let performer: LeaveSharedNodePerforming = await volumeBatchPerformerResolver.performer(
            for: nodeUid.volumeID,
            volumeIDs: volumeIDs,
            filePerformer: dependencies.performer,
            photoPerformer: dependencies.photoPerformer,
            context: context
        )
        try await performer.leaveSharedNode(nodeUid: nodeUid.sdkUid, cancellationToken: UUID(), moc: context)
    }
}

// MARK: - Photos
extension NodeOperationPerformer {
    public func findPhotoDuplicates(
        name: String,
        sha1: Data
    ) async throws -> [AnyVolumeIdentifier] {
        let uids = try await dependencies.photoPerformer.findPhotoDuplicates(
            name: name,
            sha1: sha1,
            cancellationToken: UUID()
        )
        return uids.map(\.any)
    }

    public func updatePhotos(
        _ updates: [SDKPhotoTagsUpdate]
    ) throws -> AsyncThrowingStream<SDKNodeOperationStreamEvent,any Error> {
        assertionFailure("not test yet")
        throw NSError(domain: "SDK", code: -999, localizedDescription: "updatePhotos is not tested yet")
        let sdkUpdates: [PhotoTagsUpdate] = try photoTagsUpdates(from: updates)
        let inner = dependencies.photoPerformer.updatePhotos(sdkUpdates, moc: context)
        return mapNodeOperationStream(inner)
    }

    private func photoTagsUpdates(from updates: [SDKPhotoTagsUpdate]) throws -> [PhotoTagsUpdate] {
        return try updates.map { update in
            PhotoTagsUpdate(
                nodeUid: update.nodeUid.sdkUid,
                tagsToAdd: try map(tags: update.tagsToAdd),
                tagsToRemove: try map(tags: update.tagsToRemove)
            )
        }
    }

    private func map(tags: [Int]) throws -> [PhotoTag] {
        let mappedTags = tags.compactMap { PhotoTag(rawValue: $0) }
        guard mappedTags.count == tags.count else {
            throw PhotoTagMappingError.invalidTag(tags: tags)
        }
        return mappedTags
    }

    private func mapNodeOperationStream(
        _ inner: AsyncThrowingStream<NodeOperationStreamEvent, Error>
    ) -> AsyncThrowingStream<SDKNodeOperationStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in inner {
                        switch event {
                        case .nodeResults(let results, let affectedIdentifiers):
                            continuation.yield(
                                .nodeResults(
                                    results: results.map { ($0.nodeUid.any, error: $0.error) },
                                    affectedIdentifiers: affectedIdentifiers
                                )
                            )
                        case .completed(let error):
                            continuation.yield(.completed(error: error))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

extension NodeOperationPerformer {
    public struct Dependencies {
        public let performer: FileOperationPerformer
        public let photoPerformer: PhotosOperationPerformer
        let fileBatchPerformer: NodeBatchStreamPerforming
        let photoBatchPerformer: NodeBatchStreamPerforming
        public let context: NSManagedObjectContext
        public let storage: StorageManager

        public init(
            performer: FileOperationPerformer,
            photoPerformer: PhotosOperationPerformer,
            context: NSManagedObjectContext,
            storage: StorageManager
        ) {
            self.performer = performer
            self.photoPerformer = photoPerformer
            self.fileBatchPerformer = performer
            self.photoBatchPerformer = photoPerformer
            self.context = context
            self.storage = storage
        }
    }
}

enum PhotoTagMappingError: Error {
    case invalidTag(tags: [Int])
}
