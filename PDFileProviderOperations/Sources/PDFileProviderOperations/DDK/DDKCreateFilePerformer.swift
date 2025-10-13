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

import FileProvider
import CoreData
import PDCore
import PDDesktopDevKit
import PDFileProvider
import ProtonDriveProtos

final class DDKCreateFilePerformer: CreateFilePerformer {
    
    let protonDriveClientProvider: ProtonDriveClientProvider
    let thumbnailProvider: ThumbnailProvider
    let ddkMetadataUpdater: DDKMetadataUpdater
    let updateProgress: (NSFileProviderItemIdentifier, Progress) -> Void
    
    init(protonDriveClientProvider: ProtonDriveClientProvider,
         thumbnailProvider: ThumbnailProvider,
         ddkMetadataUpdater: DDKMetadataUpdater,
         updateProgress: @escaping (NSFileProviderItemIdentifier, Progress) -> Void) {
        self.protonDriveClientProvider = protonDriveClientProvider
        self.thumbnailProvider = thumbnailProvider
        self.ddkMetadataUpdater = ddkMetadataUpdater
        self.updateProgress = updateProgress
    }
    
    public func createFile(tower: PDCore.Tower,
                           item itemTemplate: NSFileProviderItem,
                           with url: URL?,
                           under parent: PDCore.Folder,
                           progress: Progress?,
                           logOperation: Bool) async throws -> (PDCore.Node, NSManagedObjectContext) {
        
        let operationLog = logOperation ? OperationLog(operation: .create, info: "template identifier: " + itemTemplate.itemIdentifier.rawValue) : nil
        
        do {
            
            guard itemTemplate.parentItemIdentifier != .trashContainer else {
                throw Errors.excludeFromSync
            }
            
            let cancellationTokenSource = CancellationTokenSource()
            let originalCancellationHandler = progress?.cancellationHandler
            progress?.setOneTimeCancellationHandler { _ in
                cancellationTokenSource.cancel()
                originalCancellationHandler?()
            }
            
            guard let protonDriveClient = await protonDriveClientProvider.protonDriveClient else {
                throw NSFileProviderError(.serverUnreachable)
            }
            
            let (fileSize, fileUrl) = try performIfNotCancelled(progress: progress) {
                guard let url else {
                    try throwIfNotCancelled(progress: progress, error: Errors.urlForUploadIsNil)
                }
                guard let fileSize = url.fileSize else {
                    try throwIfNotCancelled(progress: progress, error: Errors.urlForUploadHasNoSize)
                }
                guard let fileUrl = try ItemActionsOutlet.prepare(forUpload: itemTemplate, from: url) else {
                    try throwIfNotCancelled(progress: progress, error: Errors.urlForUploadFailedCopying)
                }
                return (fileSize, fileUrl)
            }
            
            // this relies on all asynchronous operations in the Task being performed through Swift Concurrency
            defer {
                try? FileManager.default.removeItem(at: fileUrl.deletingLastPathComponent())
            }
            
            let (parentFolderIdentity, addressId) = try await performIfNotCancelled(progress: progress) {
                try await DDKFileProviderOperations.nodeIdentityAndContextShareAddressId(of: parent, tower: tower)
            }
            
            let shareMetadata = try await performIfNotCancelled(progress: progress) {
                try await DDKFileProviderOperations.shareMetadata(identity: parentFolderIdentity, addressId: addressId, tower: tower)
            }
            let lastModificationDate = itemTemplate.contentModificationDate?.flatMap { $0.timeIntervalSince1970 }
            ?? Date().timeIntervalSince1970
            
            let thumbnail = try performIfNotCancelled(progress: progress) {
                thumbnailProvider.thumbnailData(fileUrl: fileUrl)
            }
            
            guard let encodedFilename = itemTemplate.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let encodedFilenameURL = URL(string: "/" + encodedFilename) else {
                try throwIfNotCancelled(progress: progress, error: Errors.invalidFilename(filename: itemTemplate.filename))
            }
            
            Log.trace("Before FileUploadRequest.with")
            
            let fileUploadRequest = FileUploadRequest.with {
                $0.parentFolderIdentity = parentFolderIdentity
                $0.shareMetadata = shareMetadata
                $0.sourceFilePath = fileUrl.path(percentEncoded: false)
                $0.lastModificationDate = Int64(lastModificationDate)
                if let thumbnail {
                    $0.thumbnail = thumbnail
                }
                
                $0.name = itemTemplate.filename
                $0.mimeType = encodedFilenameURL.mimeType()
                $0.operationID = .forFileUpload(fileUrl: fileUrl)
            }
            
            let fileUploaderCreationRequest = FileUploaderCreationRequest.with {
                $0.fileSize = Int64(fileSize)
                $0.numberOfSamples = thumbnail.isNil ? 0 : 1
            }
            
            let fileUploadResponse = try await performIfNotCancelled(progress: progress) {
                do {
                    return try await protonDriveClient.uploadFile(
                        fileUploaderCreationRequest: fileUploaderCreationRequest,
                        fileUploadRequest: fileUploadRequest,
                        cancellationTokenSource: cancellationTokenSource
                    ) { [weak self] progressUpdate in
                        guard let progress else { return }
                        try? progress.update(from: progressUpdate)
                        Log.debug("Updated upload progress to \(progressUpdate) for \(itemTemplate.itemIdentifier)", domain: .fileProvider)
                        self?.updateProgress(itemTemplate.itemIdentifier, progress)
                    }
                } catch {
                    try await Self.reportIntegrityMetric(
                        error: error, parent: parent, storage: tower.storage, itemTemplate: itemTemplate, fileSize: fileSize
                    )
                }
            }
            
            // We don't wrap this call in `performIfNotCancelled` by design. If the operation has been
            // successfully performed on the BE, it's better to have the known BE state reflected in the metadata DB.
            // This way, if system for whatever reason enumerates the file in the future, it will get the right state.
            let moc = tower.storage.newBackgroundContext(mergePolicy: .mergeByPropertyObjectTrump)
            let node = try await ddkMetadataUpdater.updateMetadataAfterSuccessfulFileUpload(
                fileUploaderCreationRequest: fileUploaderCreationRequest,
                fileUploadRequest: fileUploadRequest,
                fileUploadResponse: fileUploadResponse,
                itemTemplate: itemTemplate,
                in: moc
            ).get()
            
            operationLog.map {
                $0.logEnd(moc.performAndWait { node.identifierWithinManagedObjectContext })
            }
            return (node, moc)
        } catch {
            operationLog?.logEnd(error: error)
            throw error
        }
    }
}

extension DDKCreateFilePerformer {
    
    private static func reportIntegrityMetric(
        error: Swift.Error,
        parent: Node,
        storage: StorageManager,
        itemTemplate: NSFileProviderItem,
        fileSize: Int
    ) async throws -> Never {
        guard let type = error.integrityMetricErrorType(),
              let moc = parent.managedObjectContext,
              let shares = try? storage.fetchShares(moc: moc),
              let share = await moc.perform({ shares.first { $0.id == parent.shareId } })
        else { throw error }
        
        DDKError.sendIntegrityMetricFromFileUpload(
            type: type,
            share: share,
            identifier: itemTemplate.itemIdentifier.id,
            // we're not using itemTemplate.creationDate?.flatMap { $0 } by design, because it indicates the file creation date,
            // and we're interested in when this file was uploaded, not when it was created
            creationDate: Date.now,
            fileSize: Int64(fileSize),
            in: moc
        )

        throw error
    }
}
