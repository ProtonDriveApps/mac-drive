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
import Combine
import PDClient
import PDCore
import PDDesktopDevKit
import PDFileProvider
import ProtonCoreCryptoGoInterface
import ProtonCoreNetworking
import ProtonCoreLog
import ProtonCoreUtilities
import ProtonDriveProtos

/// DDK implementations of file provider operations.
public final class DDKFileProviderOperations: FileProviderOperationsProtocol {
    private let tower: Tower
    private let syncReporter: SyncReporter
    private let manager: NSFileProviderManager
    let thumbnailProvider: ThumbnailProvider
    let ddkMetadataUpdater: DDKMetadataUpdater
    let ddkSessionCommunicator: SessionRelatedCommunicatorBetweenMainAppAndExtensions
    let protonDriveClientProvider: ProtonDriveClientProvider

    // FIXME: Remove itemProvider and itemActionsOutlet after implementing the methods which currently fall back to LegacyFileProviderOperations.
    private let itemProvider: ItemProvider
    private let itemActionsOutlet: ItemActionsOutlet
    private let progresses: FileOperationProgresses
    private let enableRegressionTestHelpers: Bool
    private let ignoreSslCertificateErrors: Bool

    private var isDDKSessionAvailable: Bool {
        tower.sessionVault.isDDKSessionAvailable
    }

    private let downloadCollector: ProgressPerformanceCollector
    private let uploadCollector: ProgressPerformanceCollector

    public required init(
        tower: Tower,
        sessionCommunicatorUserDefaults: UserDefaults,
        syncReporter: SyncReporter,
        itemProvider: ItemProvider,
        manager: NSFileProviderManager,
        thumbnailProvider: ThumbnailProvider = ThumbnailProviderFactory.defaultThumbnailProvider,
        ddkMetadataUpdater: DDKMetadataUpdater? = nil,
        downloadCollector: ProgressPerformanceCollector,
        uploadCollector: ProgressPerformanceCollector,
        progresses: FileOperationProgresses,
        enableRegressionTestHelpers: Bool,
        ignoreSslCertificateErrors: Bool
    ) async {

        self.tower = tower
        self.syncReporter = syncReporter
        self.itemProvider = itemProvider
        self.manager = manager
        self.thumbnailProvider = thumbnailProvider
        let ddkMetadataUpdater = ddkMetadataUpdater ?? DDKMetadataUpdater(storage: tower.storage)
        self.ddkMetadataUpdater = ddkMetadataUpdater
        var createFilePerformerProvider: CreateFilePerformerProvider = { DefaultCreateFilePerformer() }
        var newRevisionUploadPerformerProvider: NewRevisionUploadPerformerProvider = { DefaultNewRevisionUploadPerformer() }
        self.itemActionsOutlet = ItemActionsOutlet(fileProviderManager: manager,
                                                   fileCreationProvider: { await createFilePerformerProvider() },
                                                   newRevisionUploadPerformProvider: { await newRevisionUploadPerformerProvider() })
        self.progresses = progresses
        self.enableRegressionTestHelpers = enableRegressionTestHelpers
        self.ignoreSslCertificateErrors = ignoreSslCertificateErrors
        var onChildSessionObtained: (Credential, ChildSessionCredentialKind) async -> Void = { _, _ in }
        self.ddkSessionCommunicator = SessionRelatedCommunicatorForExtension(
            userDefaultsConfiguration: .forDDK(userDefaults: sessionCommunicatorUserDefaults),
            sessionStorage: tower.sessionVault,
            childSessionKind: .ddk,
            onChildSessionObtained: { await onChildSessionObtained($0, $1) }
        )
        self.protonDriveClientProvider = ProtonDriveClientProvider(
            storage: tower.storage,
            sessionVault: tower.sessionVault,
            networking: tower.networking,
            telemetrySettings: LocalTelemetrySettingRepository(localSettings: tower.localSettings),
            ddkMetadataUpdater: ddkMetadataUpdater,
            ddkSessionCommunicator: ddkSessionCommunicator,
            ignoreSslCertificateErrors: ignoreSslCertificateErrors
        )

        self.uploadCollector = uploadCollector
        self.downloadCollector = downloadCollector

        onChildSessionObtained = { [weak self] credential, kind in
            guard kind == .ddk, let self else { return }
            let errorMessage = await self.protonDriveClientProvider.renewProtonApiSession(credential: credential)
            guard let errorMessage else { return }
            Log.error("DDK session renewing failed", domain: .sessionManagement, context: LogContext(errorMessage))
        }

        initializeDDKLogging()

        createFilePerformerProvider = { [weak self] in
            guard let self else { return DefaultCreateFilePerformer() }
            return createDDKCreateFilePerformer()
        }

        newRevisionUploadPerformerProvider = { [weak self] in
            guard let self else { return DefaultNewRevisionUploadPerformer() }
            return DDKNewRevisionUploadPerformer(delegate: self) { [weak self] in
                self?.syncReporter.updateProgress(itemIdentifier: $0, progress: $1)
            }
        }

        syncReporter.nodeInformationExtractor = { node in
            return node.moc?.performAndWait {
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

        await ddkSessionCommunicator.performInitialSetup()

        await protonDriveClientProvider.createProtonClientIfNeeded()

        guard isDDKSessionAvailable else {
            await ddkSessionCommunicator.askMainAppToProvideNewChildSession()
            return
        }
    }

    private static func volumeID(_ tower: Tower) -> String? {
        let moc = tower.storage.backgroundContext
        return moc.performAndWait {
            return try? tower.storage.getMyVolumeId(in: moc)
        }
    }

    public func item(for identifier: NSFileProviderItemIdentifier,
                     request: NSFileProviderRequest,
                     completionHandler: @escaping (_ item: NSFileProviderItem?,
                                                   _ error: Swift.Error?) -> Void) -> Progress {

        // TODO: Implement using DDK
        let operationLog = OperationLog.logStart(of: .fetchItem, additional: identifier)
        let fileProviderOperations = LegacyFileProviderOperations(
            tower: tower,
            syncReporter: syncReporter,
            itemProvider: itemProvider,
            manager: manager,
            itemActionsOutlet: itemActionsOutlet,
            progresses: progresses,
            enableRegressionTestHelpers: enableRegressionTestHelpers,
            downloadCollector: downloadCollector,
            uploadCollector: uploadCollector
        )

        let retainedFileProviderOperations = RetainCycleBox(value: fileProviderOperations)

        return fileProviderOperations.item(for: identifier, request: request, completionHandler: {
            retainedFileProviderOperations.breakRetainCycle()
            operationLog.logEnd(error: $1)
            completionHandler($0, $1)
        })
    }

    // MARK: - Error parsing

    func requestNewChildSessionIfNecessary(_ error: Swift.Error) async {
        if case .invalidRefreshToken = error as? DDKError {
            Log.trace("true")
            await ddkSessionCommunicator.askMainAppToProvideNewChildSession()
        } else {
            Log.trace("false")
        }
    }

    static func parseErrorFromDDKBackedOperation(_ error: Swift.Error, _ logPrefix: String) -> Swift.Error {
        Log.trace()
        let fileProviderCompatibleError = error.toFileProviderCompatibleError()
        return fileProviderCompatibleError
    }
    
    private static func reportIntegrityMetric(
        error: Swift.Error,
        itemIdentifier: NSFileProviderItemIdentifier,
        storage: StorageManager
    ) async throws -> Never {
        guard let type = error.integrityMetricErrorType(),
              let nodeIdentifier = NodeIdentifier(itemIdentifier),
              let node = storage.fetchNode(id: nodeIdentifier, moc: storage.backgroundContext),
              let shares = try? storage.fetchShares(moc: storage.backgroundContext),
              let share = await storage.backgroundContext.perform({ shares.first { $0.id == node.shareId } })
        else { throw error }
        
        DDKError.sendIntegrityMetric(type: type, share: share, node: node, in: storage.backgroundContext)
        
        throw error
    }

    // MARK: - Progress

    private func didStartFileUploadOperation(progress: Progress) {
        progresses.add(progress)
        uploadCollector.startObserving(progress: progress, using: .legacy)
    }

    private func didCompleteFileUploadOperation(progress: Progress?) {
        guard let progress else { return }
        uploadCollector.finishObserving(progress: progress, using: .legacy)
        didCompleteFileOperation(progress: progress)
    }

    private func didStartFileDownloadOperation(progress: Progress) {
        downloadCollector.startObserving(progress: progress, using: .legacy)
        progresses.add(progress)
    }

    private func didCompleteFileDownloadOperation(progress: Progress?) {
        guard let progress else { return }

        downloadCollector.finishObserving(progress: progress, using: .legacy)
        didCompleteFileOperation(progress: progress)
    }

    private func didCompleteFileOperation(progress: Progress) {
        Log.trace()

        progresses.remove(progress)
        progress.clearOneTimeCancellationHandler()
    }

    // MARK: - Download file

    public func fetchContents(itemIdentifier: NSFileProviderItemIdentifier,
                              requestedVersion: NSFileProviderItemVersion?,
                              completionHandler: @escaping (_ fileContents: URL?,
                                                            _ item: NSFileProviderItem?,
                                                            _ error: Swift.Error?) -> Void) -> Progress {

        let operationLog = OperationLog.logStart(of: .fetchContents, additional: itemIdentifier)

        // early exit so that the request is not restarted when the session is still not available
        // otherwise it might fail and cause another session forking
        guard !ddkSessionCommunicator.isWaitingforNewChildSession else {
            operationLog.logEnd("call exited early due to ddk child session being fetched")
            completionHandler(nil, nil, CocoaError(.userCancelled))
            return Progress()
        }

        // wrapper is used because we leak the passed completion block on operation cancellation, so we need to ensure
        // that the system-provided completion block (which retains extension instance) is not leaked after being called
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)

        syncReporter.didStartFileOperation(
            itemIdentifier: itemIdentifier, 
            operation: .fetchContents, 
            changedFields: [], 
            withoutLocation: false
        )

        let cancellationTokenSource = CancellationTokenSource()
        let progress = Progress(totalUnitCount: 1) { cancelledProgress in
            let cancellationReason = cancelledProgress?.cancellationReason ?? .unknown
            Log.trace("Cancelling progress: \(cancellationReason)")
            cancellationTokenSource.cancel()
        }

        Task(priority: .userInitiated) {
            do {
                try abortIfCancelled(progress: progress)

                guard let protonDriveClient = await self.protonDriveClientProvider.protonDriveClient else {
                    throw NSFileProviderError(.serverUnreachable)
                }

                let (fileDownloadRequest, nodeItem, url) = try await performIfNotCancelled(progress: progress) {
                    try await self.fileDownloadRequest(itemIdentifier: itemIdentifier, tower: self.tower)
                }
                progress.totalUnitCount = nodeItem.documentSize?.int64Value ?? 1

                let verificationStatus = try await performIfNotCancelled(progress: progress) {
                    do {
                        return try await protonDriveClient.downloadFile(
                            fileDownloadRequest: fileDownloadRequest,
                            cancellationTokenSource: cancellationTokenSource
                        ) { [weak self] progressUpdate in
                            
                            try? progress.update(from: progressUpdate)
                            Log.debug("Updated download progress to \(progressUpdate) for \(itemIdentifier)", domain: .fileProvider)
                            
                            self?.syncReporter
                                .updateProgress(
                                    itemIdentifier: itemIdentifier,
                                    progress: progress
                                )
                        }
                    } catch {
                        try await Self.reportIntegrityMetric(error: error, itemIdentifier: itemIdentifier, storage: tower.storage)
                    }
                }

                if verificationStatus != .ok {
                    Log
                        .error(
                            "File download verification failure",
                            domain: .fileProvider,
                            context: LogContext("Verification status: \(verificationStatus)")
                        )
                }

                // We don't wrap this call in `performIfNotCancelled` by design. If the operation has been
                // successfully performed on the BE, it's better to have the known BE state reflected in the metadata DB.
                // This way, if system for whatever reason enumerates the file in the future, it will get the right state.
                let moc = tower.storage.newBackgroundContext(mergePolicy: .mergeByPropertyObjectTrump)
                let updatedNodeItem = try await ddkMetadataUpdater
                    .updateMetadataAfterSuccessfulDownload(fileDownload: fileDownloadRequest, in: moc)
                    .get()

                try abortIfCancelled(progress: progress)

                didCompleteFileDownloadOperation(progress: progress)

                syncReporter.didCompleteFileOperation(
                    itemIdentifier: itemIdentifier,
                    possibleError: nil,
                    during: .fetchContents,
                    withoutLocation: false
                )
                operationLog.logEnd()
                completionBlockWrapper(url, updatedNodeItem, nil)
            } catch {
                Log.error("fetchContents failed", error: error, domain: .fileProvider)

                didCompleteFileDownloadOperation(progress: progress)

                syncReporter.didCompleteFileOperation(
                    itemIdentifier: itemIdentifier,
                    possibleError: error,
                    during: .fetchContents,
                    withoutLocation: false
                )
                await requestNewChildSessionIfNecessary(error)
                let fileProviderCompatibleError = DDKFileProviderOperations.parseErrorFromDDKBackedOperation(error, "Download")
                operationLog.logEnd(error: error)
                completionBlockWrapper(nil, nil, fileProviderCompatibleError)
            }
        }
        didStartFileDownloadOperation(progress: progress)
        return progress
    }

    private func fileDownloadRequest(itemIdentifier: NSFileProviderItemIdentifier, tower: Tower) async throws -> (FileDownloadRequest, NodeItem, URL) {

        guard let nodeIdentifier = NodeIdentifier(itemIdentifier) else {
            throw Errors.nodeIdentifierNotFound(identifier: itemIdentifier)
        }
        guard let child = await tower.node(itemIdentifier: itemIdentifier) as? File else {
            throw Errors.nodeNotFound(identifier: itemIdentifier)
        }
        guard let volumeID = Self.volumeID(tower) else {
            throw Errors.rootNotFound
        }

        let revisionMetadata = try? await Self.revisionMetadata(file: child, tower: tower)

        let (filename, nodeItem) = try await tower.storage.backgroundContext.perform {
            return (try child.decryptName(), try NodeItem(node: child))
        }

        let sanitizedFilename = filename.filenameSanitizedForFilesystem()
        let url = PDFileManager.prepareUrlForFile(named: sanitizedFilename)

        let fileIdentity = NodeIdentity.with {
            $0.nodeID.value = nodeIdentifier.nodeID
            $0.shareID.value = nodeIdentifier.shareID
            $0.volumeID.value = volumeID
        }

        let fileDownloadRequest = FileDownloadRequest.with {
            $0.fileIdentity = fileIdentity
            if let revisionMetadata {
                $0.revisionMetadata = revisionMetadata
            }
            $0.targetFilePath = url.path(percentEncoded: false)
            $0.operationID = .forFileDownload(fileIdentity: fileIdentity)
        }

        return (fileDownloadRequest, nodeItem, url)
    }

    // MARK: - Upload file

    private func createDDKCreateFilePerformer() -> DDKCreateFilePerformer {
        DDKCreateFilePerformer(protonDriveClientProvider: protonDriveClientProvider,
                               thumbnailProvider: thumbnailProvider,
                               ddkMetadataUpdater: ddkMetadataUpdater) { [weak self] in
            self?.syncReporter.updateProgress(itemIdentifier: $0, progress: $1)
        }
    }

    // swiftlint:disable:next function_parameter_count
    public func createItem(basedOn itemTemplate: NSFileProviderItem,
                           fields: NSFileProviderItemFields,
                           contents url: URL?,
                           options: NSFileProviderCreateItemOptions,
                           request: NSFileProviderRequest,
                           completionHandler: @escaping (_ createdItem: NSFileProviderItem?,
                                                         _ stillPendingFields: NSFileProviderItemFields,
                                                         _ shouldFetchContent: Bool,
                                                         _ error: Swift.Error?) -> Void) -> Progress {

        let operationLog = OperationLog.logStart(
            of: .create,
            additional: itemTemplate.isFolder ? "folder, " : "file, " + "template identifier: " + itemTemplate.itemIdentifier.rawValue + ", mayAlreadyExist: \(options.contains(.mayAlreadyExist)), deletionConflicted: \(options.contains(.deletionConflicted))"
        )

        guard !itemTemplate.isFolder else {

            // TODO: Implement using DDK

            // early exit so that the request is not restarted when the session is still not available
            // otherwise it might fail and cause another session forking
            guard !tower.sessionCommunicator.isWaitingforNewChildSession else {
                operationLog.logEnd("call exited early due to fpe child session being fetched")
                completionHandler(nil, [], false, CocoaError(.userCancelled))
                return Progress()
            }

            let fileProviderOperations = LegacyFileProviderOperations(
                tower: tower, syncReporter: syncReporter,
                itemProvider: itemProvider, manager: manager, itemActionsOutlet: itemActionsOutlet,
                progresses: progresses,
                enableRegressionTestHelpers: enableRegressionTestHelpers,
                downloadCollector: downloadCollector,
                uploadCollector: uploadCollector
            )
            let retainedFileProviderOperations = RetainCycleBox(value: fileProviderOperations)
            return fileProviderOperations.createItem(basedOn: itemTemplate, fields: fields, contents: url,
                                                     options: options, request: request) {
                retainedFileProviderOperations.breakRetainCycle()
                operationLog.logEnd($0?.itemIdentifier, error: $3)
                completionHandler($0, $1, $2, $3)
            }
        }

        // early exit so that the request is not restarted when the session is still not available
        // otherwise it might fail and cause another session forking
        guard !ddkSessionCommunicator.isWaitingforNewChildSession else {
            operationLog.logEnd("call exited early due to ddk child session being fetched")
            completionHandler(nil, [], false, CocoaError(.userCancelled))
            return Progress()
        }

        guard !options.contains(.mayAlreadyExist) else {
            // inspired by Apple's sample code from
            // https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions
            completionHandler(nil, [], false, nil)
            return Progress()
        }

        // wrapper is used because we leak the passed completion block on operation cancellation, so we need to ensure
        // that the system-provided completion block (which retains extension instance) is not leaked after being called
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)

        let progress = Progress(totalUnitCount: Int64(url?.fileSize ?? 0)) { cancelledProgress in
            let cancellationReason = cancelledProgress?.cancellationReason ?? .unknown
            Log.trace("Cancelling progress: \(cancellationReason)")
        }

        let withoutLocation = options.contains(.mayAlreadyExist) || url == nil

        syncReporter.didStartFileOperation(
            item: itemTemplate,
            operation: .create,
            changedFields: fields,
            withoutLocation: withoutLocation
        )

        Task(priority: .userInitiated) {
            do {
                let parent = try await performIfNotCancelled(progress: progress) {
                    guard itemTemplate.parentItemIdentifier != .trashContainer else {
                        throw Errors.excludeFromSync
                    }
                    guard let parent = await self.tower.parentFolder(of: itemTemplate) else {
                        throw Errors.parentNotFound(identifier: itemTemplate.parentItemIdentifier)
                    }
                    return parent
                }

                let (node, context) = try await createDDKCreateFilePerformer().createFile(
                    tower: tower, item: itemTemplate, with: url, under: parent, progress: progress, logOperation: false
                )

                // There is no cancellation check here by design. The rationale: if we managed to successfully perform the DDK operation,
                // it's better to have the new BE state correctly represented in the metadata DB instead of it being lack of sync.
                let item = try await context.perform {
                    do {
                        return try NodeItem(node: node)
                    } catch {
                        throw DDKMetadataUpdater.MetadataUpdateError.metadataUpdateFailed(inner: error)
                    }
                }

                try abortIfCancelled(progress: progress)

                didCompleteFileUploadOperation(progress: progress)
                syncReporter.didCompleteFileOperation(
                    item: item,
                    possibleError: nil,
                    during: .create,
                    changedFields: fields,
                    temporaryItem: itemTemplate,
                    withoutLocation: withoutLocation
                )
                operationLog.logEnd(item.itemIdentifier)
                completionBlockWrapper(item, [], false, nil)
            } catch {
                var logContext = LogContext()
                logContext["item"] = itemTemplate.itemIdentifier.rawValue
                logContext["parent"] = itemTemplate.parentItemIdentifier.rawValue
                Log.error("createItem failed - \(error.localizedDescription.upTo("\n"))", error: error, domain: .fileProvider, context: logContext)

                didCompleteFileUploadOperation(progress: progress)
                syncReporter.didCompleteFileOperation(
                    item: itemTemplate,
                    possibleError: error,
                    during: .create,
                    changedFields: fields,
                    temporaryItem: itemTemplate,
                    withoutLocation: withoutLocation
                )

                await requestNewChildSessionIfNecessary(error)
                let fileProviderCompatibleError = Self.parseErrorFromDDKBackedOperation(error, "File upload")
                let fields = fileProviderCompatibleError.isUserCancelledError ? [] : fields
                operationLog.logEnd(error: error)
                completionBlockWrapper(nil, fields, false, fileProviderCompatibleError)
            }
        }
        didStartFileUploadOperation(progress: progress)
        return progress
    }

    static func nodeIdentityAndContextShareAddressId(of node: Node, tower: Tower) async throws -> (NodeIdentity, String?) {
        let (nodeIdentifier, volumeID, addressId): (PDCore.NodeIdentifier, String, String?) = try await tower.storage.backgroundContext.perform {
            guard let volumeID = Self.volumeID(tower) else {
                throw Errors.nodeIdentifierNotFound(identifier: NSFileProviderItemIdentifier(node.identifierWithinManagedObjectContext))
            }
            do {
                let addressId = try node.getContextShareAddressID()
                return (node.identifierWithinManagedObjectContext, volumeID, addressId)
            } catch {
                Log.warning("DDKFileProviderOperations.nodeIdentityAndContextShareAddressId.getContextShareAddressID failed with error: \(error.localizedDescription)",
                            domain: .encryption)
                return (node.identifierWithinManagedObjectContext, volumeID, nil)
            }
        }

        return (NodeIdentity.with {
            $0.nodeID.value = nodeIdentifier.nodeID
            $0.shareID.value = nodeIdentifier.shareID
            $0.volumeID.value = volumeID
        }, addressId)
    }

    static func shareMetadata(
        identity: ProtonDriveProtos.NodeIdentity, addressId: String?, tower: Tower
    ) async throws -> ProtonDriveProtos.ShareMetadata {
        if addressId == nil {
            Log.warning("DDKFileProviderOperations.shareMetadata called without addressId", domain: .encryption)
        }
        let addressToUse = addressId.map { tower.sessionVault.getAddress(withId: $0) } ?? tower.sessionVault.currentAddress()
        guard let addressToUse else {
            throw Errors.noAddressInTower
        }
        return ProtonDriveProtos.ShareMetadata.with {
            $0.shareID = identity.shareID
            $0.membershipAddressID.value = addressToUse.addressID
            $0.membershipEmailAddress = addressToUse.email
        }
    }

    private static func revisionMetadata(file: File, tower: Tower) async throws -> RevisionMetadata {
        try await tower.storage.backgroundContext.perform { () throws -> RevisionMetadata in

            guard let revision = file.activeRevision,
                  let revisionState = revision.state,
                  let armoredSignature = revision.manifestSignature,
                  let signatureEmailAddress = revision.signatureAddress
            else {
                throw Errors.revisionNotFound
            }

            let unarmoredSignature = try executeAndUnwrap { CryptoGo.ArmorUnarmor(armoredSignature, &$0) }

            let samplesSha256Digests = revision.thumbnails.compactMap(\.sha256)

            let revisionMetadata = RevisionMetadata.with {
                $0.revisionID.value = revision.id
                $0.state = RevisionState(rawValue: revisionState.rawValue)!
                $0.manifestSignature = unarmoredSignature
                $0.signatureEmailAddress = signatureEmailAddress
                $0.samplesSha256Digests = samplesSha256Digests
            }

            return revisionMetadata
        }
    }

    // MARK: - Upload revision

    // swiftlint:disable:next function_parameter_count
    public func modifyItem(_ item: NSFileProviderItem,
                           baseVersion version: NSFileProviderItemVersion,
                           changedFields: NSFileProviderItemFields,
                           contents newContents: URL?,
                           options: NSFileProviderModifyItemOptions,
                           request: NSFileProviderRequest,
                           completionHandler: @escaping (_ item: NSFileProviderItem?,
                                                         _ stillPendingFields: NSFileProviderItemFields,
                                                         _ shouldFetchContent: Bool,
                                                         _ error: Swift.Error?) -> Void) -> Progress {

        // TODO: Implement using DDK

        // early exit so that the request is not restarted when the session is still not available
        // otherwise it might fail and cause another session forking
        guard !tower.sessionCommunicator.isWaitingforNewChildSession else {
            Log.info("Modify item — call exited early due to fpe child session being fetched", domain: .fileProvider)
            completionHandler(nil, [], false, CocoaError(.userCancelled))
            return Progress()
        }

        let fileProviderOperations = LegacyFileProviderOperations(
            tower: tower,
            syncReporter: syncReporter,
            itemProvider: itemProvider,
            manager: manager,
            itemActionsOutlet: itemActionsOutlet,
            progresses: progresses,
            enableRegressionTestHelpers: enableRegressionTestHelpers,
            downloadCollector: downloadCollector,
            uploadCollector: uploadCollector
        )
        let retainedFileProviderOperations = RetainCycleBox(value: fileProviderOperations)

        return fileProviderOperations.modifyItem(item,
                                                 baseVersion: version,
                                                 changedFields: changedFields,
                                                 contents: newContents,
                                                 options: options,
                                                 request: request,
                                                 completionHandler: {
            retainedFileProviderOperations.breakRetainCycle()
            completionHandler($0, $1, $2, $3)
        })
    }

    // MARK: - Delete file

    public func deleteItem(identifier: NSFileProviderItemIdentifier,
                           baseVersion version: NSFileProviderItemVersion,
                           options: NSFileProviderDeleteItemOptions,
                           request: NSFileProviderRequest,
                           completionHandler: @escaping ((any Swift.Error)?) -> Void) -> Progress {

        // TODO: Implement using DDK

        let operationLog = OperationLog.logStart(of: .delete, additional: "\(identifier), recursive: \(options.contains(.recursive))")

        // early exit so that the request is not restarted when the session is still not available
        // otherwise it might fail and cause another session forking
        guard !tower.sessionCommunicator.isWaitingforNewChildSession else {
            operationLog.logEnd("call exited early due to fpe child session being fetched")
            completionHandler(CocoaError(.userCancelled))
            return Progress()
        }

        let fileProviderOperations = LegacyFileProviderOperations(
            tower: tower,
            syncReporter: syncReporter,
            itemProvider: itemProvider,
            manager: manager,
            itemActionsOutlet: itemActionsOutlet,
            progresses: progresses,
            enableRegressionTestHelpers: enableRegressionTestHelpers,
            downloadCollector: downloadCollector,
            uploadCollector: uploadCollector
        )
        let retainedFileProviderOperations = RetainCycleBox(value: fileProviderOperations)

        return fileProviderOperations.deleteItem(
            identifier: identifier,
            baseVersion: version,
            request: request,
            completionHandler: {
                retainedFileProviderOperations.breakRetainCycle()
                operationLog.logEnd(error: $0)
                completionHandler($0)
            })
    }

    // MARK: - Other

    public func flushObservabilityService() async {
        await protonDriveClientProvider.flushObservability()
    }

    private func initializeDDKLogging() {
        LoggerProvider.configureLoggingCallback { level, message, category in
            let domain: LogDomain
            var logMessage = message
            switch category {
            case .download: domain = .downloader
            case .upload: domain = .uploader
            case .other(let category):
                domain = .ddk
                if !category.isEmpty {
                    logMessage = "[\(category)] \(logMessage)"
                }
            }
            switch level {
            case .trace, .debug: Log.debug(logMessage, domain: domain)
            case .information: Log.info(logMessage, domain: domain)
            case .warning: Log.warning(logMessage, domain: domain)
            case .error, .critical: Log.error(logMessage, domain: domain)
            case .none: return
            }
        }
    }
}

extension Swift.Error {
    var isUserCancelledError: Bool {
        guard let cocoaError = self as? CocoaError else { return false }
        return cocoaError.code == .userCancelled
    }
}

extension String {
    func upTo(_ separator: Character) -> String {
        var index = startIndex
        while index < endIndex, self[index] != separator {
            index = self.index(after: index)
        }
        return String(self[..<index])
    }
}
