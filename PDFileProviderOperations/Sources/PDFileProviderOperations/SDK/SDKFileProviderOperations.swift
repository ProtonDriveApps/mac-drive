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

// swiftlint:disable function_parameter_count

import FileProvider
import Combine
import CoreData
import PDClient
@preconcurrency import PDCore
import PDFileProvider
import PDSDKCore
import ProtonDriveSDK
import ProtonCoreCryptoGoInterface
import ProtonCoreNetworking
import ProtonCoreLog
import ProtonCoreUtilities

// TODO(SDK): Implement the remaining delegate methods using the SDK
/// SDK implementations of file provider operations.
public final class SDKFileProviderOperations: FileProviderOperationsProtocol {
    private let tower: Tower
    private let syncReporter: SyncReporter
    private let fileOperationPerformer: FileOperationPerformer
    private let legacyFileProviderOperations: LegacyFileProviderOperations
    private let progresses: FileOperationProgresses

    private let downloadPerformanceCollector: ProgressPerformanceCollector
    private let uploadPerformanceCollector: ProgressPerformanceCollector
    private let networkOfflineDetector: NetworkOfflineDetector
    private let folderRateLimiter: FolderRateLimiter
    private let quotaLimiter: QuotaLimiter

    public convenience init(
        tower: Tower,
        syncReporter: SyncReporter,
        fileProviderManager: NSFileProviderManager,
        progresses: FileOperationProgresses,
        enableRegressionTestHelpers: Bool = false,
        downloadPerformanceCollector: ProgressPerformanceCollector,
        uploadPerformanceCollector: ProgressPerformanceCollector
    ) async throws {
        let userInfoController = UserInfoControllerFactory().makeController(sessionVault: tower.sessionVault)
        let observabilityReporter = ObservabilityReporter(dependencies: .init(userInfoController: userInfoController))
        let fileVerifier = FileVerifier(observabilityReporter: observabilityReporter)

        try await self.init(
            tower: tower,
            syncReporter: syncReporter,
            fileProviderManager: fileProviderManager,
            progresses: progresses,
            enableRegressionTestHelpers: enableRegressionTestHelpers,
            downloadPerformanceCollector: downloadPerformanceCollector,
            uploadPerformanceCollector: uploadPerformanceCollector,
            fileVerifier: fileVerifier,
            observabilityReporter: observabilityReporter,
            folderRateLimiter: FolderRateLimiter(
                folderStateProvider: CoreDataFolderStateProvider()
            ),
            quotaLimiter: QuotaLimiter(
                storage: UserDefaultsQuotaLimiterStorage(),
                quotaResource: tower.sessionVault
            )
        )
    }

    init(
        tower: Tower,
        syncReporter: SyncReporter,
        fileProviderManager: NSFileProviderManager,
        progresses: FileOperationProgresses,
        enableRegressionTestHelpers: Bool = false,
        downloadPerformanceCollector: ProgressPerformanceCollector,
        uploadPerformanceCollector: ProgressPerformanceCollector,
        fileVerifier: FileVerificationProtocol,
        observabilityReporter: ObservabilityReporterProtocol,
        folderRateLimiter: FolderRateLimiter,
        quotaLimiter: QuotaLimiter
    ) async throws {
        let protonDriveClientConfiguration = ProtonDriveClientConfiguration(
            baseURL: tower.clientConfiguration.driveApiBase,
            clientUID: tower.sessionVault.getUploadClientUID(),
            downloadOperationalResilience: BasicOperationalResilience.default,
            uploadOperationalResilience: BasicOperationalResilience.default,
            entityCachePath: tower.sdkCacheProvider.entityCacheURL.path(percentEncoded: false),
            secretCachePath: tower.sdkCacheProvider.secretCacheURL.path(percentEncoded: false),
            secretCacheEncryptionKey: tower.sdkEncryptionKeyProvider?.getOrCreateEncryptionKey()
        )
        let fileOperationPerformer = try await FileOperationPerformer(
            protonDriveClientConfiguration: protonDriveClientConfiguration,
            storage: tower.storage,
            networking: tower.networking,
            accountClient: tower.sessionVault,
            rateLimitGate: tower.rateLimitGate,
            urlCacheCleaner: URLCacheCleaner(session: tower.networking),
            fileVerifier: fileVerifier,
            observabilityReporter: observabilityReporter,
            featureFlagProviderCallback: defaultFeatureFlagProviderCallback(featureFlags: tower.featureFlags)
        )

        let sdkUploadPerformer = SDKUploadPerformer(
            fileOperationPerformer: fileOperationPerformer,
            thumbnailProvider: ThumbnailProviderFactory.defaultSynchronizedThumbnailProvider,
            quotaLimiter: quotaLimiter
        )
        let createFilePerformer: CreateFilePerformer = sdkUploadPerformer
        let newRevisionUploadPerformer: NewRevisionUploadPerformer = sdkUploadPerformer

        let itemActionsOutlet = ItemActionsOutlet(
            fileProviderManager: fileProviderManager,
            fileCreationProvider: { createFilePerformer },
            newRevisionUploadPerformProvider: { newRevisionUploadPerformer },
            providersPipeline: .default,
            folderRateLimiter: folderRateLimiter
        )

        self.legacyFileProviderOperations = LegacyFileProviderOperations(
            tower: tower,
            syncReporter: syncReporter,
            itemProvider: ItemProvider(),
            manager: fileProviderManager,
            itemActionsOutlet: itemActionsOutlet,
            progresses: progresses,
            enableRegressionTestHelpers: enableRegressionTestHelpers,
            downloadCollector: downloadPerformanceCollector,
            uploadCollector: uploadPerformanceCollector
        )

        self.tower = tower
        self.syncReporter = syncReporter
        self.progresses = progresses
        self.downloadPerformanceCollector = downloadPerformanceCollector
        self.uploadPerformanceCollector = uploadPerformanceCollector
        self.fileOperationPerformer = fileOperationPerformer

        self.networkOfflineDetector = NetworkOfflineDetector(
            connectionStateResource: tower.connectionStateResource
        )
        self.folderRateLimiter = folderRateLimiter
        self.quotaLimiter = quotaLimiter

        syncReporter.nodeInformationExtractor = { node in
            do {
                let filename = try node.decryptNameWithCryptoGo()
                let mimeType = try NodeItem(node: node).mimeType ?? node.mimeType
                return (filename: filename, mimeType: mimeType, size: node.presentableNodeSize)
            } catch {
                Log.error("Filename decryption failed", error: error, domain: .fileProvider)
                return (filename: "Filename decryption failed", mimeType: node.mimeType, size: node.presentableNodeSize)
            }
        }
    }

    // TODO: Add convenience init after we remove LegacyFileProviderOperations

    public func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (_ item: NSFileProviderItem?,
                                      _ error: Swift.Error?) -> Void
    ) -> Progress {
        return legacyFileProviderOperations.item(for: identifier, request: request, completionHandler: completionHandler)
    }

    public func fetchContents(
        itemIdentifier: NSFileProviderItemIdentifier,
        requestedVersion: NSFileProviderItemVersion?,
        completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void
    ) -> Progress {

        let parentIDFetcher = tower.parentIDFetcher
        let operationToken = UUID()
        let progress = Progress(totalUnitCount: 0) { progress in
            Task {
                try await self.fileOperationPerformer.cancelDownload(cancellationToken: operationToken)
            }
        }
        progresses.add(progress)

        Task {
            try await tower.storage.backgroundContextPool.withContext { moc in

                guard !earlyExitAndCallCompletionHandlerIfNoChildSession(
                    tower, "fetchContents", completionHandler(nil, nil, CocoaError(.userCancelled))
                ) else {
                    Log.event(.fetchContents(.failed(.init(id: itemIdentifier.logIdentifier,
                                                           errorMessage: "No child session"))))
                    progress.clearOneTimeCancellationHandler()
                    progresses.remove(progress)
                    return
                }

                guard let node = await tower.node(itemIdentifier: itemIdentifier, in: moc) else {
                    progress.clearOneTimeCancellationHandler()
                    progresses.remove(progress)
                    let error = Errors.nodeNotFound(identifier: itemIdentifier)
                    Log.event(.fetchContents(.failed(.init(id: itemIdentifier.logIdentifier,
                                                           error: error))))
                    return completionHandler(
                        nil,
                        nil,
                        error.toFileProviderCompatibleError()
                    )
                }

                syncReporter.didStartFileOperation(
                    itemIdentifier: itemIdentifier,
                    operation: .fetchContents,
                    changedFields: [],
                    withoutLocation: false
                )

                let (filename, nodeItem, shareID) = try await moc.perform {
                    return (try node.decryptName(), try NodeItem(node: node), node.shareId)
                }

                progress.totalUnitCount = nodeItem.documentSize?.int64Value ?? 0

                // Bail early if already cancelled (e.g. network went offline during node lookup)
                if progress.isCancelled {
                    progress.clearOneTimeCancellationHandler()
                    progresses.remove(progress)

                    let reportError: Error = networkOfflineDetector.isLikelyOffline(progress: progress)
                    ? CancellationReason.networkOffline
                    : CocoaError(.userCancelled)

                    syncReporter.didCompleteFileOperation(
                        itemIdentifier: itemIdentifier,
                        possibleError: reportError,
                        during: .fetchContents,
                        withoutLocation: false
                    )
                    Log.event(.fetchContents(.failed(.init(id: itemIdentifier.logIdentifier,
                                                           error: reportError))))
                    completionHandler(nil, nodeItem, CocoaError(.userCancelled) as NSError)
                    return
                }

                let sanitizedFilename = filename.filenameSanitizedForFilesystem()
                let url = PDFileManager.prepareUrlForFile(named: sanitizedFilename)
                let revisionUID = try await self.revisionId(node: node, storage: tower.storage, moc: moc)

                downloadPerformanceCollector.startObserving(progress: progress, using: .default)

                do {
                    // the verification issues are ignored for now, to keep the behaviour consistent with the legacy pipeline
                    let (revision, _) = try await self.fileOperationPerformer.downloadFile(
                        revisionUid: revisionUID,
                        destinationUrl: url,
                        shareID: shareID,
                        cancellationToken: operationToken,
                        progressCallback: { [weak syncReporter, weak progress] callbackProgress in
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

                            syncReporter?.updateProgress(
                                itemIdentifier: itemIdentifier,
                                progress: progress
                            )
                        },
                        onRetriableErrorReceived: { error in
                            // TODO: decide if and how this error should be shown to the user
                        },
                        shouldThrowOnManifestVerificationIssues: false,
                        moc: moc
                    )

                    let file = await moc.perform { revision.file }
                    let downloadedNodeItem = try NodeItem(node: file)

                    syncReporter.didCompleteFileOperation(
                        itemIdentifier: itemIdentifier,
                        possibleError: nil,
                        during: .fetchContents,
                        withoutLocation: false
                    )

                    progress.clearOneTimeCancellationHandler()
                    progresses.remove(progress)
                    downloadPerformanceCollector.finishObserving(progress: progress, using: .default)

                    Log.event(.fetchContents(.succeeded(.init(
                        itemID: downloadedNodeItem.itemIdentifier.logIdentifier,
                        parentIDs: await parentIDFetcher.fetchParentIDs(for: downloadedNodeItem.itemIdentifier.logIdentifier),
                        fetchedVersion: downloadedNodeItem.itemVersion.sha256
                    ))))

                    completionHandler(url, downloadedNodeItem, nil)
                } catch {
                    let reportError: Error = networkOfflineDetector.isLikelyOffline(progress: progress, error: error)
                    ? CancellationReason.networkOffline
                    : error

                    syncReporter.didCompleteFileOperation(
                        itemIdentifier: itemIdentifier,
                        possibleError: reportError,
                        during: .fetchContents,
                        withoutLocation: false
                    )

                    Log.event(.fetchContents(.failed(.init(id: itemIdentifier.logIdentifier,
                                                           error: reportError))))

                    let fpError = error.toFileProviderCompatibleError()

                    progress.clearOneTimeCancellationHandler()
                    progresses.remove(progress)
                    downloadPerformanceCollector.finishObserving(progress: progress, using: .default)

                    completionHandler(nil, nodeItem, fpError)
                }
            }
        }

        return progress
    }

    public func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        let parentIDFetcher = tower.parentIDFetcher
        if options.contains(.mayAlreadyExist) {
            // inspired by the Apple's sample code from
            // https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions
            Log.event(.createItem(.failed(.init(id: itemTemplate.itemIdentifier.logIdentifier, errorMessage: "mayAlreadyExist"))))
            completionHandler(nil, [], false, nil)
            return Progress()
        }

        if itemTemplate.isFolder {
            return legacyFileProviderOperations.createItem(
                basedOn: itemTemplate,
                fields: fields,
                contents: url,
                options: options,
                request: request,
                completionHandler: completionHandler
            )
        }

        if itemTemplate.isProtonFile {
            Log.event(.createItem(.failed(.init(id: itemTemplate.itemIdentifier.logIdentifier, errorMessage: "isProtonFile"))))
            completionHandler(nil, [], false, Errors.excludeFromSync.toFileProviderCompatibleError())
            return Progress()
        }

        guard let url else {
            Log.event(.createItem(.failed(.init(id: itemTemplate.itemIdentifier.logIdentifier, errorMessage: "no url"))))
            completionHandler(nil, [], false, Errors.urlForUploadIsNil.toFileProviderCompatibleError())
            return Progress()
        }

        let operationToken = UUID()

        let progress = Progress(totalUnitCount: url.fileSize.map(Int64.init) ?? itemTemplate.documentSize??.int64Value ?? 0) { progress in
            Task {
                try await self.fileOperationPerformer.cancelUpload(cancellationToken: operationToken)
            }
        }
        progresses.add(progress)

        Task {
            await tower.storage.backgroundContextPool.withContext { moc in
                guard !earlyExitAndCallCompletionHandlerIfNoChildSession(
                    tower, "createItem", completionHandler(nil, [], false, CocoaError(.userCancelled))
                ) else {
                    Log.event(.createItem(.failed(.init(id: itemTemplate.itemIdentifier.logIdentifier,
                                                            errorMessage: "No child session"))))
                    progress.clearOneTimeCancellationHandler()
                    progresses.remove(progress)
                    return
                }

                guard let folder = await tower.parentFolder(of: itemTemplate, in: moc) else {
                    progress.clearOneTimeCancellationHandler()
                    progresses.remove(progress)
                    let error = Errors.parentNotFound(identifier: itemTemplate.itemIdentifier)
                    Log.event(.createItem(.failed(.init(id: itemTemplate.itemIdentifier.logIdentifier, error: error))))
                    completionHandler(nil, [], false, error.toFileProviderCompatibleError())
                    return
                }

                let parentIdentifier = await moc.perform { folder.identifierWithinManagedObjectContext }
                let shareID = parentIdentifier.shareID

                // We now guarantee that an URL is provided and that we don't
                // run this code if options contains .mayAlreadyExist, so withoutLocation
                // can be hardcoded to false for now.
                syncReporter.didStartFileOperation(
                    item: itemTemplate,
                    operation: .create,
                    changedFields: fields,
                    withoutLocation: false
                )

                // Bail early if already cancelled (e.g. network went offline during folder lookup)
                if progress.isCancelled {
                    progress.clearOneTimeCancellationHandler()
                    progresses.remove(progress)

                    let reportError: Error = networkOfflineDetector.isLikelyOffline(progress: progress)
                    ? CancellationReason.networkOffline
                    : CocoaError(.userCancelled)

                    syncReporter.didCompleteFileOperation(
                        item: itemTemplate,
                        possibleError: reportError,
                        during: .create,
                        changedFields: fields,
                        temporaryItem: itemTemplate,
                        withoutLocation: false
                    )

                    Log.event(.createItem(.failed(.init(id: itemTemplate.itemIdentifier.logIdentifier,
                                                        error: reportError))))

                    completionHandler(nil, [], false, CocoaError(.userCancelled) as NSError)
                    return
                }

                uploadPerformanceCollector.startObserving(progress: progress, using: .default)

                do {
                    let fileAttributes = FileAttributes(url: url, itemTemplate: itemTemplate)
                    let pipeline = UploadLimiterPipeline([
                        self.quotaLimiter.withContext(clearFileSize: fileAttributes.fileSize, kind: .file),
                        self.folderRateLimiter.withContext(parent: parentIdentifier, in: moc),
                    ])
                    let nodeItem: NodeItem = try await pipeline.runOperation {
                        let newNode = try await self.fileOperationPerformer.uploadFile(
                            parentFolderUid: try await self.folderId(folder: folder, storage: tower.storage, moc: moc),
                            name: itemTemplate.filename.filenameSanitizedForFilesystem(),
                            url: url,
                            fileAttributes: fileAttributes,
                            shareID: shareID,
                            mediaType: itemTemplate.mimeType ?? "",
                            cancellationToken: operationToken,
                            progressCallback: { [weak syncReporter, weak progress] callbackProgress in
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

                                syncReporter?.updateProgress(
                                    itemIdentifier: itemTemplate.itemIdentifier,
                                    progress: progress
                                )
                            },
                            onRetriableErrorReceived: { error in
                                // TODO: decide if and how this error should be shown to the user
                            },
                            moc: moc,
                            thumbnailProvider: ThumbnailProviderFactory.defaultSynchronizedThumbnailProvider,
                            conflictResolution: .newRevision
                        )
                        return try await moc.perform { try NodeItem(node: newNode) }
                    }

                    syncReporter.didCompleteFileOperation(
                        item: nodeItem,
                        possibleError: nil,
                        during: .create,
                        changedFields: fields,
                        temporaryItem: itemTemplate,
                        withoutLocation: false
                    )

                    progress.clearOneTimeCancellationHandler()
                    progresses.remove(progress)
                    uploadPerformanceCollector.finishObserving(progress: progress, using: .default)

                    Log.event(.createItem(.succeeded(.init(
                        itemID: nodeItem.itemIdentifier.logIdentifier,
                        parentIDs: await parentIDFetcher.fetchParentIDs(for: nodeItem.itemIdentifier.logIdentifier),
                        createdVersion: nodeItem.itemVersion.sha256
                    ))))

                    completionHandler(nodeItem, [], false, nil)
                } catch {
                    let reportError: Error = networkOfflineDetector.isLikelyOffline(progress: progress, error: error)
                        ? CancellationReason.networkOffline
                        : error

                    syncReporter.didCompleteFileOperation(
                        item: itemTemplate,
                        possibleError: reportError,
                        during: .create,
                        changedFields: fields,
                        temporaryItem: itemTemplate,
                        withoutLocation: false
                    )

                    Log.event(.createItem(.failed(.init(id: itemTemplate.itemIdentifier.logIdentifier,
                                                        error: reportError))))

                    let fpError = error.toFileProviderCompatibleError()

                    progress.clearOneTimeCancellationHandler()
                    progresses.remove(progress)
                    uploadPerformanceCollector.finishObserving(progress: progress, using: .default)

                    completionHandler(nil, fields, false, fpError)
                }
            }
        }

        return progress
    }

    public func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?) -> Void
    ) -> Progress {
        return legacyFileProviderOperations.modifyItem(
            item,
            baseVersion: version,
            changedFields: changedFields,
            contents: newContents,
            options: options,
            request: request,
            completionHandler: completionHandler
        )
    }

    public func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions,
        request: NSFileProviderRequest,
        completionHandler: @escaping ((any Swift.Error)?) -> Void
    ) -> Progress {
        return legacyFileProviderOperations.deleteItem(
            identifier: identifier,
            baseVersion: version,
            request: request,
            completionHandler: completionHandler
        )
    }

    // TODO: These should be migrated somewhere else once we isolate Node/Revisions or we have to
    // reuse in another layer of the application.
    private func revisionId(node: Node?, storage: StorageManager, moc: NSManagedObjectContext) async throws -> SDKRevisionUid {
        return try await moc.perform {
            guard
                let file = node as? File,
                let revision = file.activeRevision
            else {
                throw Errors.revisionNotFound
            }
            guard let volumeID = try? storage.getMyVolumeId(in: moc) else {
                throw Errors.rootNotFound
            }
            return SDKRevisionUid(volumeID: volumeID, nodeID: file.id, revisionID: revision.id)
        }
    }

    // TODO: These should be migrated somewhere else once we isolate Node/Revisions or we have to
    // reuse in another layer of the application.
    private func folderId(folder: Folder?, storage: StorageManager, moc: NSManagedObjectContext) async throws -> SDKNodeUid {
        guard let folder else {
            throw Errors.revisionNotFound
        }

        let possibleVolumeID = moc.performAndWait {
            return try? storage.getMyVolumeId(in: moc)
        }

        guard let volumeID = possibleVolumeID else {
            throw Errors.rootNotFound
        }

        return SDKNodeUid(volumeID: volumeID, nodeID: folder.identifier.nodeID)
    }
}

public extension PDCore.FileOperationEvent.EventSource {
    init(_ request: NSFileProviderRequest) {
        if request.isSystemRequest {
            self = .system
        } else if request.isFileViewerRequest {
            self = .fileViewer
        } else if let requestingExecutable = request.requestingExecutable {
            self = .executable(requestingExecutable)
        } else {
            self = .unknown
        }
    }
}

public extension NSFileProviderItemVersion {
    var sha256: String {
        (self.metadataVersion + self.contentVersion ).sha256().base64EncodedString()
    }
}

public extension FileOperationEvent.CreateItemOptions {
    init(_ options: NSFileProviderCreateItemOptions) {
        var result: Self = .init()
        if options.contains(.mayAlreadyExist) {
            result.update(with: .mayAlreadyExist)
        }
        if options.contains(.deletionConflicted) {
            result.update(with: .deletionConflicted)
        }
        self = result
    }
}

public extension FileOperationEvent.ItemFields {
    init(_ fields: NSFileProviderItemFields) {
        var result: Self = []
        if fields.contains(.contents) {
            result.insert(.contents)
        }
        if fields.contains(.filename) {
            result.insert(.filename)
        }
        if fields.contains(.parentItemIdentifier) {
            result.insert(.parentItemIdentifier)
        }
        if fields.contains(.lastUsedDate) {
            result.insert(.lastUsedDate)
        }
        if fields.contains(.tagData) {
            result.insert(.tagData)
        }
        if fields.contains(.favoriteRank) {
            result.insert(.favoriteRank)
        }
        if fields.contains(.creationDate) {
            result.insert(.creationDate)
        }
        if fields.contains(.contentModificationDate) {
            result.insert(.contentModificationDate)
        }
        if fields.contains(.fileSystemFlags) {
            result.insert(.fileSystemFlags)
        }
        if fields.contains(.extendedAttributes) {
            result.insert(.extendedAttributes)
        }
        if fields.contains(.typeAndCreator) {
            result.insert(.typeAndCreator)
        }
        self = result
    }
}

public extension FileOperationEvent.ModifyItemOptions {
    init(_ options: NSFileProviderModifyItemOptions) {
        var result: Self = []
        if options.contains(.mayAlreadyExist) {
            result.insert(.mayAlreadyExist)
        }
        if #available(macOS 26.0, *) {
            if options.contains(.failOnConflict) {
                result.insert(.failOnConflict)
            }
            if options.contains(.isImmediateUploadRequestByPresentingApplication) {
                result.insert(.isImmediateUploadRequestByPresentingApplication)
            }
        }
        self = result
    }
}

public extension FileOperationEvent.ContainerType {
    init(_ identifier: NSFileProviderItemIdentifier) {
        if identifier == .workingSet {
            self = .workingSet
        } else if identifier == .rootContainer {
            self = .rootContainer
        } else if identifier == .trashContainer {
            self = .trashContainer
        } else {
            self = .folder(identifier.logIdentifier)
        }
    }
}

// swiftlint:enable function_parameter_count
