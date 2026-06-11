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

import CoreData
import FileProvider
import Foundation

@preconcurrency import PDCore
import PDFileProvider
import PDSDKCore
import ProtonDriveSDK

// swiftlint:disable function_parameter_count large_tuple

final class SDKUploadPerformer: CreateFilePerformer, NewRevisionUploadPerformer {

    private let fileOperationPerformer: FileOperationPerformer
    private let thumbnailProvider: SynchronizedThumbnailProviderProtocol
    private let quotaLimiter: QuotaLimiter

    init(
        fileOperationPerformer: FileOperationPerformer,
        thumbnailProvider: SynchronizedThumbnailProviderProtocol,
        quotaLimiter: QuotaLimiter
    ) {
        self.fileOperationPerformer = fileOperationPerformer
        self.thumbnailProvider = thumbnailProvider
        self.quotaLimiter = quotaLimiter
    }

    public func createFile(
        tower: PDCore.Tower,
        item: NSFileProviderItem,
        with contents: URL?,
        under parent: PDCore.Folder,
        progress: Progress?,
        logOperation: Bool,
        moc: NSManagedObjectContext
    ) async throws -> PDCore.Node {
        let (cancellationToken, progress, volumeID) = try commonPrework(
            item: item, storage: tower.storage, progress: progress, moc: moc
        )

        guard let (nodeID, shareID) = await moc.perform({
            let parent = moc.object(with: parent.objectID) as? Node
            return parent.map { ($0.id, $0.shareID) }
        }) else {
            try throwIfNotCancelled(progress: progress, error: Errors.nodeIdentifierNotFound(identifier: item.itemIdentifier))
        }

        guard let url = contents else {
            try throwIfNotCancelled(progress: progress, error: Errors.urlForUploadIsNil)
        }

        guard let fileUrl = try ItemActionsOutlet.prepare(forUpload: item, from: url) else {
            try throwIfNotCancelled(progress: progress, error: Errors.urlForUploadFailedCopying)
        }

        guard let encodedFilename = item.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedFilenameURL = URL(string: "/" + encodedFilename) else {
            try throwIfNotCancelled(progress: progress, error: Errors.invalidFilename(filename: item.filename))
        }

        let fileAttributes = FileAttributes(url: fileUrl, itemTemplate: item)
        let pipeline = UploadLimiterPipeline([
            quotaLimiter.withContext(clearFileSize: fileAttributes.fileSize, kind: .file),
        ])
        let node = try await pipeline.runOperation {
            try await fileOperationPerformer.uploadFile(
                parentFolderUid: SDKNodeUid(volumeID: volumeID, nodeID: nodeID),
                name: item.filename,
                url: fileUrl,
                fileAttributes: fileAttributes,
                shareID: shareID,
                mediaType: encodedFilenameURL.mimeType(),
                cancellationToken: cancellationToken,
                progressCallback: { [weak progress] callbackProgress in
                    if let progress,
                       let bytesTotal = callbackProgress.bytesTotal,
                       progress.totalUnitCount != bytesTotal {
                       // progress update is guarded because it's costly on the XPC side (can cause global progress hanging)
                        progress.totalUnitCount = bytesTotal
                    }
                    if let progress,
                       let bytesCompleted = callbackProgress.bytesCompleted,
                       progress.completedUnitCount != bytesCompleted {
                        progress.completedUnitCount = bytesCompleted
                    }
                },
                onRetriableErrorReceived: { error in
                    // TODO: decide if and how this error should be shown to the user
                },
                moc: moc,
                thumbnailProvider: thumbnailProvider,
                conflictResolution: .newRevision
            )
        }

        return node
    }

    public func uploadNewRevision(
        item: NSFileProviderItem,
        file: PDCore.File,
        tower: PDCore.Tower,
        copy: URL,
        fileSize: Int,
        pendingFields: NSFileProviderItemFields,
        progress: Progress?,
        moc: NSManagedObjectContext
    ) async throws -> (NSFileProviderItem?, NSFileProviderItemFields, Bool) {
        let (cancellationToken, progress, volumeID) = try commonPrework(
            item: item, storage: tower.storage, progress: progress, moc: moc
        )

        let (nodeID, revisionID, shareID) = try await moc.perform {
            guard let file = moc.object(with: file.objectID) as? File,
                  let revision = file.activeRevision
            else { throw Errors.revisionNotFound }
            return (file.id, revision.id, file.shareID)
        }
        let currentActiveRevisionUid = SDKRevisionUid(volumeID: volumeID, nodeID: nodeID, revisionID: revisionID)

        let fileAttributes = FileAttributes(url: copy, itemTemplate: item)
        let pipeline = UploadLimiterPipeline([
            quotaLimiter.withContext(clearFileSize: fileAttributes.fileSize, kind: .file),
        ])
        let node = try await pipeline.runOperation {
            try await fileOperationPerformer.uploadNewRevision(
                currentActiveRevisionUid: currentActiveRevisionUid,
                url: copy,
                fileAttributes: fileAttributes,
                shareID: shareID,
                thumbnailProvider: thumbnailProvider,
                cancellationToken: cancellationToken,
                progressCallback: { [weak progress] callbackProgress in
                    if let progress,
                       let bytesTotal = callbackProgress.bytesTotal,
                       // progress update is guarded because it's costly on the XPC side (can cause global progress hanging)
                       progress.totalUnitCount != bytesTotal {
                        progress.totalUnitCount = bytesTotal
                    }
                    if let progress,
                       let bytesCompleted = callbackProgress.bytesCompleted,
                       progress.completedUnitCount != bytesCompleted {
                        progress.completedUnitCount = bytesCompleted
                    }
                },
                onRetriableErrorReceived: { error in
                    // TODO: decide if and how this error should be shown to the user
                },
                moc: moc
            )
        }

        let item = try NodeItem(node: node)
        var leftoverFields = pendingFields
        leftoverFields.remove(.contents)
        return (item, leftoverFields, false)
    }

    private func commonPrework(
        item: NSFileProviderItem, storage: StorageManager, progress: Progress?, moc: NSManagedObjectContext
    ) throws -> (UUID, Progress, String) {
        let cancellationToken = UUID()
        let progress = progress ?? Progress(totalUnitCount: 0)
        if progress.totalUnitCount == 0 {
            progress.totalUnitCount = item.documentSize??.int64Value ?? 0
        }
        progress.cancellationHandler = {
            Task {
                try await self.fileOperationPerformer.cancelUpload(cancellationToken: cancellationToken)
            }
        }
        let volumeID = try storage.getMyVolumeId(in: moc)
        return (cancellationToken, progress, volumeID)
    }
}

// swiftlint:enable function_parameter_count large_tuple
