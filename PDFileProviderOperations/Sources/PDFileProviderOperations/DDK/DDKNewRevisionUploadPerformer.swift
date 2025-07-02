// Copyright (c) 2024 Proton AG
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

import FileProvider
import PDCore
import PDDesktopDevKit
import PDFileProvider

protocol DDKNewRevisionUploadPerformerDelegate: AnyObject {
    var thumbnailProvider: ThumbnailProvider { get }
    var ddkMetadataUpdater: DDKMetadataUpdater { get }
    var ddkSessionCommunicator: SessionRelatedCommunicatorBetweenMainAppAndExtensions { get }
    var protonDriveClientProvider: ProtonDriveClientProvider { get }

    func requestNewChildSessionIfNecessary(_ error: Swift.Error) async
}

extension DDKFileProviderOperations: DDKNewRevisionUploadPerformerDelegate {}

final class DDKNewRevisionUploadPerformer: NewRevisionUploadPerformer {

    private weak var delegate: DDKNewRevisionUploadPerformerDelegate?
    private let dateFormatter = ISO8601DateFormatter()
    private let updateProgress: (NSFileProviderItemIdentifier, Progress) -> Void

    init(delegate: DDKNewRevisionUploadPerformerDelegate, updateProgress: @escaping (NSFileProviderItemIdentifier, Progress) -> Void) {
        self.delegate = delegate
        self.updateProgress = updateProgress
    }

    // swiftlint:disable:next function_parameter_count function_body_length
    func uploadNewRevision(
        item: NSFileProviderItem, file: File, tower: Tower, copy: URL,
        fileSize: Int, pendingFields: NSFileProviderItemFields, progress: Progress?
    ) async throws -> (NSFileProviderItem?, NSFileProviderItemFields, Bool) {

        let operationLog = OperationLog.logStart(of: .update, additional: "\(item.itemIdentifier), changedFields: \(pendingFields.rawValue)")

        let cancellationTokenSource = CancellationTokenSource()
        let originalProgressCancellationHandler = progress?.cancellationHandler
        _ = try performIfNotCancelled(progress: progress) {
            progress?.setOneTimeCancellationHandler { progress in
                cancellationTokenSource.cancel()
                Log.info("Upload revision call cancelled", domain: .fileProvider)
                originalProgressCancellationHandler?()
            }
        }

        guard let delegate else {
            Log.error("Upload revision call exited early due to lack of delegate", domain: .fileProvider)
            throw CocoaError(.userCancelled)
        }

        // early exit so that the request is not restarted when the session is still not available
        // otherwise it might fail and cause another session forking
        guard !delegate.ddkSessionCommunicator.isWaitingforNewChildSession else {
            Log.error("Upload revision call exited early due to ddk child session being fetched", domain: .fileProvider)
            throw CocoaError(.userCancelled)
        }

        guard let protonDriveClient = await delegate.protonDriveClientProvider.protonDriveClient else {
            Log.error("Upload revision call exited early due to lack of protonDriveClient", domain: .fileProvider)
            throw CocoaError(.userCancelled)
        }

        let moc = tower.storage.newBackgroundContext(mergePolicy: .mergeByPropertyObjectTrump)
        let uploadingFile = await moc.perform {
            let uploadingFile = moc.object(with: file.objectID) as? File
            uploadingFile?.isUploading = true
            try? moc.save()
            return uploadingFile
        }
        defer {
            moc.performAndWait {
                uploadingFile?.isUploading = false
                try? moc.save()
            }
        }

        do {
            guard item.parentItemIdentifier != .trashContainer else {
                throw Errors.excludeFromSync
            }

            let fileIdentity = try await performIfNotCancelled(progress: progress) {
                try await DDKFileProviderOperations.nodeIdentity(of: file, tower: tower)
            }

            let shareMetadata = try await performIfNotCancelled(progress: progress) {
                try await DDKFileProviderOperations.shareMetadata(identity: fileIdentity, tower: tower)
            }

            let thumbnail = try performIfNotCancelled(progress: progress) {
                delegate.thumbnailProvider.thumbnailData(fileUrl: copy)
            }

            let lastModificationDate = item.contentModificationDate?.flatMap { $0.timeIntervalSince1970 }
                ?? Date.now.timeIntervalSince1970

            let fileUploaderCreationRequest = FileUploaderCreationRequest.with {
                $0.fileSize = Int64(fileSize)
                $0.numberOfSamples = thumbnail.isNil ? 0 : 1
            }

            let revisionUploadRequest = RevisionUploadRequest.with {
                $0.fileIdentity = fileIdentity
                $0.shareMetadata = shareMetadata
                if let thumbnail {
                    $0.thumbnail = thumbnail
                }
                $0.lastModificationDate = Int64(lastModificationDate)
                $0.sourceFilePath = copy.path(percentEncoded: false)
                $0.operationID = .forRevisionUpload(fileIdentity: fileIdentity)
            }

            let outputRevision = try await performIfNotCancelled(progress: progress) { [weak self] in
                do {
                    return try await protonDriveClient.uploadRevision(
                        fileUploaderCreationRequest: fileUploaderCreationRequest,
                        revisionUploadRequest: revisionUploadRequest,
                        cancellationTokenSource: cancellationTokenSource,
                        onProgressUpdate: { [weak self, weak progress] progressUpdate in
                            guard let progress else { return }

                            try? progress.update(from: progressUpdate)
                            Log.debug("Updated upload new revision progress to \(progressUpdate) for \(item.itemIdentifier)", domain: .fileProvider)

                            self?.updateProgress(item.itemIdentifier, progress)
                        }
                    )
                } catch {
                    try await Self.reportIntegrityMetric(error: error, file: file, storage: tower.storage)
                }
            }

            // We don't wrap this call in `performIfNotCancelled` by design. If the operation has been
            // successfully performed on the BE, it's better to have the known BE state reflected in the metadata DB.
            // This way, if system for whatever reason enumerates the file in the future, it will get the right state.
            let item = try await delegate.ddkMetadataUpdater.updateMetadataAfterSuccessfulRevisionUpload(
                item: item,
                fileUploaderCreationRequest: fileUploaderCreationRequest,
                revisionUploadRequest: revisionUploadRequest,
                revision: outputRevision,
                in: moc
            ).get()
            var leftoverFields = pendingFields
            leftoverFields.remove(.contents)
            operationLog.logEnd("stillPendingFields: \(leftoverFields.rawValue)")
            return (item, leftoverFields, false)
        } catch {
            await delegate.requestNewChildSessionIfNecessary(error)
            operationLog.logEnd(error: error)
            try throwIfNotCancelled(progress: progress, error: DDKFileProviderOperations.parseErrorFromDDKBackedOperation(error, "Revision upload"))
        }
    }
}

extension DDKNewRevisionUploadPerformer {
    
    private static func reportIntegrityMetric(error: Swift.Error, file: Node, storage: StorageManager) async throws -> Never {
        guard let type = error.integrityMetricErrorType(),
              let moc = file.managedObjectContext,
              let shares = try? storage.fetchShares(moc: moc),
              let share = await moc.perform({ shares.first { $0.id == file.shareId } })
        else { throw error }

        DDKError.sendIntegrityMetric(type: type, share: share, node: file, in: moc)

        throw error
    }
}
