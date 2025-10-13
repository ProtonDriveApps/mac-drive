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
import PDFileProvider

/// Pre-DDK implementations of file provider operations.
public final class LegacyFileProviderOperations: FileProviderOperationsProtocol {
    private let tower: Tower
    private let syncReporter: SyncReporter
    private let itemProvider: ItemProvider
    private let itemActionsOutlet: ItemActionsOutlet
    private let progresses: FileOperationProgresses
    private let regressionTestHelpers: RegressionTestHelpers?

    private let downloadCollector: ProgressPerformanceCollector
    private let uploadCollector: ProgressPerformanceCollector

    public required init(tower: Tower,
                         syncReporter: SyncReporter,
                         itemProvider: ItemProvider,
                         manager: NSFileProviderManager,
                         itemActionsOutlet: ItemActionsOutlet? = nil,
                         progresses: FileOperationProgresses,
                         enableRegressionTestHelpers: Bool,
                         downloadCollector: ProgressPerformanceCollector,
                         uploadCollector: ProgressPerformanceCollector
    ) {
        self.tower = tower
        self.syncReporter = syncReporter
        self.itemProvider = itemProvider
        self.itemActionsOutlet = itemActionsOutlet ?? ItemActionsOutlet(
            fileProviderManager: manager, newRevisionUploadPerformProvider: { DefaultNewRevisionUploadPerformer() }
        )
        self.progresses = progresses
        if enableRegressionTestHelpers {
            self.regressionTestHelpers = RegressionTestHelpers()
        } else {
            self.regressionTestHelpers = nil
        }

        syncReporter.nodeInformationExtractor = { node in
            node.moc?.performAndWait {
                let filename = (try? node.decryptName()) ?? "Filename decryption failed"
                let mimeType: String = (try? NodeItem(node: node))?.mimeType ?? node.mimeType
                return (filename: filename, mimeType: mimeType, size: node.presentableNodeSize)
            }
        }

        self.downloadCollector = downloadCollector
        self.uploadCollector = uploadCollector
    }

    public func item(for identifier: NSFileProviderItemIdentifier,
                     request: NSFileProviderRequest,
                     completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {

        var itemProgress: Progress?
        
        // wrapper is used because we leak the passed completion block on operation cancellation, so we need to ensure
        // that the system-provided completion block (which retains extension instance) is not leaked after being called
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)
        
        let creatorsIfRoot = identifier == .rootContainer ? tower.sessionVault.addressIDs : []
        
        let progress = itemProvider.itemProgress(
            for: identifier,
            creatorAddresses: creatorsIfRoot,
            fileSystemSlot: tower.fileSystemSlot!,
            cloudSlot: tower.cloudSlot!
        ) { [weak self] item, error in
            itemProgress?.clearOneTimeCancellationHandler()
            self?.progresses.remove(itemProgress)
            guard itemProgress?.isCancelled != true else {
                completionBlockWrapper(item, error)
                return
            }
            
            let fpError = PDFileProvider.Errors.mapToFileProviderErrorIfPossible(error)
            completionBlockWrapper(item, fpError)
        }
        
        itemProgress = progress
        progresses.add(progress)
        return progress        
    }
    
    public func fetchContents(itemIdentifier: NSFileProviderItemIdentifier,
                              requestedVersion: NSFileProviderItemVersion?,
                              completionHandler: @escaping (_ fileContents: URL?,
                                                            _ item: NSFileProviderItem?,
                                                            _ error: Error?) -> Void) -> Progress {

        // early exit so that the request is not restarted when the session is still not available
        // otherwise it might fail and cause another session forking
        guard !tower.sessionCommunicator.isWaitingforNewChildSession else {
            Log.info("Fetch contents call exited early due to fpe child session being fetched", domain: .fileProvider)
            completionHandler(nil, nil, CocoaError(.userCancelled))
            return Progress()
        }

        var fetchContentsProgress: Progress?

        // wrapper is used because we leak the passed completion block on operation cancellation, so we need to ensure
        // that the system-provided completion block (which retains extension instance) is not leaked after being called
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)

        syncReporter.didStartFileOperation(itemIdentifier: itemIdentifier, operation: .fetchContents, changedFields: [], withoutLocation: false)

        let progress = itemProvider.legacyFetchContents(
            for: itemIdentifier,
            version: requestedVersion,
            fileSystemSlot: tower.fileSystemSlot!,
            downloader: tower.downloader!,
            storage: tower.storage,
            useRefreshableDownloadOperation: false
        ) { [weak self] url, item, error in
            fetchContentsProgress?.clearOneTimeCancellationHandler()
            self?.progresses.remove(fetchContentsProgress)
            guard fetchContentsProgress?.isCancelled != true else {
                completionBlockWrapper(url, item, error)
                return
            }

            self?.syncReporter.didCompleteFileOperation(
                itemIdentifier: itemIdentifier,
                possibleError: error,
                during: .fetchContents,
                withoutLocation: false)
            let fpError = PDFileProvider.Errors.mapToFileProviderErrorIfPossible(error)
            completionBlockWrapper(url, item, fpError)
        }

        didStartFileDownloadOperation(with: progress)

        fetchContentsProgress = progress
        progresses.add(progress)
        return progress
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
                                                         _ error: Error?) -> Void) -> Progress {

        // early exit so that the request is not restarted when the session is still not available
        // otherwise it might fail and cause another session forking
        guard !tower.sessionCommunicator.isWaitingforNewChildSession else {
            Log.info("Create call exited early due to fpe child session being fetched", domain: .fileProvider)
            completionHandler(nil, [], false, CocoaError(.userCancelled))
            return Progress()
        }

        guard !options.contains(.mayAlreadyExist) else {
            // inspired by the Apple's sample code from
            // https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions
            completionHandler(nil, [], false, nil)
            return Progress()
        }

        var createItemProgress: Progress?
        
        // wrapper is used because we leak the passed completion block on operation cancellation, so we need to ensure
        // that the system-provided completion block (which retains extension instance) is not leaked after being called
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)

        let withoutLocation = options.contains(.mayAlreadyExist) || url == nil

        syncReporter.didStartFileOperation(
            item: itemTemplate,
            operation: .create,
            changedFields: fields,
            withoutLocation: withoutLocation)

        let progress = itemActionsOutlet.createItem(
            tower: tower, basedOn: itemTemplate, fields: fields, contents: url, options: options, request: request
        ) { [weak self] item, fields, needUpload, error in
            createItemProgress?.clearOneTimeCancellationHandler()
            self?.progresses.remove(createItemProgress)
            guard createItemProgress?.isCancelled != true else {
                completionBlockWrapper(item, fields, needUpload, error)
                return
            }
            
            self?.syncReporter.didCompleteFileOperation(
                item: item ?? itemTemplate,
                possibleError: error,
                during: .create,
                changedFields: fields,
                temporaryItem: itemTemplate,
                withoutLocation: withoutLocation)
            let fpError = PDFileProvider.Errors.mapToFileProviderErrorIfPossible(error)
            completionBlockWrapper(item, fields, needUpload, fpError)
        }

        didStartFileUploadOperation(with: progress)

        createItemProgress = progress
        progresses.add(progress)
        return progress
    }

    // swiftlint:disable:next function_parameter_count
    public func modifyItem(_ item: NSFileProviderItem,
                           baseVersion version: NSFileProviderItemVersion,
                           changedFields: NSFileProviderItemFields,
                           contents newContents: URL?,
                           options: NSFileProviderModifyItemOptions = [],
                           request: NSFileProviderRequest,
                           completionHandler: @escaping (_ item: NSFileProviderItem?,
                                                         _ stillPendingFields: NSFileProviderItemFields,
                                                         _ shouldFetchContent: Bool,
                                                         _ error: Error?) -> Void) -> Progress
    {

        // early exit so that the request is not restarted when the session is still not available
        // otherwise it might fail and cause another session forking
        guard !tower.sessionCommunicator.isWaitingforNewChildSession else {
            Log.info("Modify call exited early due to fpe child session being fetched", domain: .fileProvider)
            completionHandler(nil, [], false, CocoaError(.userCancelled))
            return Progress()
        }

        var modifyItemProgress: Progress?

        // wrapper is used because we leak the passed completion block on operation cancellation, so we need to ensure
        // that the system-provided completion block (which retains extension instance) is not leaked after being called
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)

        let fileProviderOperation = FileProviderOperation(changedFields: changedFields)

        let withoutLocation = options.contains(.mayAlreadyExist)
        let contentsChanged = changedFields.contains(.contents)

        syncReporter.didStartFileOperation(item: item, operation: fileProviderOperation, changedFields: changedFields, withoutLocation: withoutLocation)

        let progress = itemActionsOutlet.modifyItem(
            tower: tower, item: item, baseVersion: version, changedFields: changedFields, contents: newContents,
            options: options, request: request
        ) { [weak self] modifiedItem, fields, needUpload, error in
            let error = self?.regressionTestHelpers?.error(for: item, operation: fileProviderOperation) ?? error

            modifyItemProgress?.clearOneTimeCancellationHandler()
            self?.progresses.remove(modifyItemProgress)
            guard modifyItemProgress?.isCancelled != true else {
                completionBlockWrapper(modifiedItem, fields, needUpload, error)
                return
            }

            self?.syncReporter.didCompleteFileOperation(
                item: item,
                possibleError: error,
                during: fileProviderOperation,
                changedFields: changedFields,
                withoutLocation: withoutLocation
            )
            let fpError = PDFileProvider.Errors.mapToFileProviderErrorIfPossible(error)
            completionBlockWrapper(modifiedItem, fields, needUpload, fpError)
        }

        if contentsChanged {
            didStartFileUploadOperation(with: progress)
        }

        modifyItemProgress = progress
        progresses.add(progress)
        return progress
    }
    
    public func deleteItem(identifier: NSFileProviderItemIdentifier,
                           baseVersion version: NSFileProviderItemVersion,
                           options: NSFileProviderDeleteItemOptions = [],
                           request: NSFileProviderRequest,
                           completionHandler: @escaping (Error?) -> Void) -> Progress
    {

        // early exit so that the request is not restarted when the session is still not available
        // otherwise it might fail and cause another session forking
        guard !tower.sessionCommunicator.isWaitingforNewChildSession else {
            Log.info("Delete call exited early due to fpe child session being fetched", domain: .fileProvider)
            completionHandler(CocoaError(.userCancelled))
            return Progress()
        }

        var deleteItemProgress: Progress?
        
        // wrapper is used because we leak the passed completion block on operation cancellation, so we need to ensure
        // that the system-provided completion block (which retains extension instance) is not leaked after being called
        let completionBlockWrapper = CompletionBlockWrapper(completionHandler)
        
        syncReporter.didStartFileOperation(itemIdentifier: identifier, operation: .delete, changedFields: [], withoutLocation: true)

        let progress = itemActionsOutlet.deleteItem(
            tower: tower, identifier: identifier, baseVersion: version, options: options, request: request
        ) { [weak self] error in
            
            deleteItemProgress?.clearOneTimeCancellationHandler()
            self?.progresses.remove(deleteItemProgress)
            guard deleteItemProgress?.isCancelled != true else {
                completionBlockWrapper(error)
                return
            }
            
            self?.syncReporter.didCompleteFileOperation(
                itemIdentifier: identifier,
                possibleError: error,
                during: .delete,
                withoutLocation: true)
            let fpError = PDFileProvider.Errors.mapToFileProviderErrorIfPossible(error)
            completionBlockWrapper(fpError)
        }
        
        deleteItemProgress = progress
        progresses.add(progress)
        return progress
    }
}

private extension LegacyFileProviderOperations {
    func didStartFileUploadOperation(with progress: Progress?) {
        guard let progress else { return }
        uploadCollector.startObserving(progress: progress, using: .legacy)
    }

    func didFinishFileUploadOperation(with progress: Progress?) {
        guard let progress else { return }
        uploadCollector.finishObserving(progress: progress, using: .legacy)
    }

    func didStartFileDownloadOperation(with progress: Progress?) {
        guard let progress else { return }
        downloadCollector.startObserving(progress: progress, using: .legacy)
    }

    func didFinishFileDownloadOperation(with progress: Progress?) {
        guard let progress else { return }
        downloadCollector.finishObserving(progress: progress, using: .legacy)
    }
}

private extension FileProviderOperation {
    /// NSFileProvider collectively refers to moves, renames, and updates as modifications.
    /// We want more granularity, so we break them down based on which NSFileProviderItemFields have been changed.
    init(changedFields: NSFileProviderItemFields) {
        if changedFields.contains(.parentItemIdentifier) {
            self = .move
            return
        } else if changedFields.contains(.filename) {
            self = .rename
            return
        } else if changedFields.contains(.contents) {
            self = .update
            return
        }

        // Falling back to .update, because if it's not move/rename, then it's probably an update.
        self = .update
    }
}

private extension NSFileProviderItemFields {
    var allFields: [String: NSFileProviderItemFields] {
        [
            "contents": .contents,
            "filename": .filename,
            "parentItemIdentifier": .parentItemIdentifier,
            "lastUsedDate": .lastUsedDate,
            "tagData": .tagData,
            "favoriteRank": .favoriteRank,
            "creationDate": .creationDate,
            "contentModificationDate": .contentModificationDate,
            "fileSystemFlags": .fileSystemFlags,
            "extendedAttributes": .extendedAttributes,
        ]
    }

    var includedFields: [String] {
        allFields.map { key, value in
            self.contains(value) ? key : nil
        }.compactMap { $0 }
    }
}
