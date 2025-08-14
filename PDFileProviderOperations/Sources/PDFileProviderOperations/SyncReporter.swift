// Copyright (c) 2023 Proton AG
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

import PDCore
import FileProvider
import PDFileProvider
import PDDesktopDevKit

// Tuple used to thread-safely store some information about the node
typealias NodeInformationExtractor = (Node) -> (filename: String, mimeType: String, size: Int)?

public class SyncReporter {
    private let tower: Tower
    private let manager: NSFileProviderManager

    private var syncStorage: SyncStorageManager {
        tower.syncStorage ?? SyncStorageManager(suite: .group(named: Constants.appGroup))
    }

    var nodeInformationExtractor: NodeInformationExtractor?

    public init(tower: Tower, manager: NSFileProviderManager) {
        self.tower = tower
        self.manager = manager
    }

    // MARK: File operations

    /// Used for uploads and modifications.
    func didStartFileOperation(
        item: NSFileProviderItem,
        operation: FileProviderOperation,
        changedFields: NSFileProviderItemFields,
        withoutLocation: Bool)
    {
        guard shouldConsiderItem(item, during: operation, changedFields: changedFields) else {
            Log.trace("guard !shouldConsiderItem")
            return
        }
        Log.trace()

        let filename: String
        switch operation {
        // use the internal filename rather than the normalized version provided to the local filesystem
        case .move, .update:
            filename = nodeFilename(for: item)
        default:
            filename = item.filename
        }

        Task {
            let location = withoutLocation ? "" : await shortLocation(for: item.itemIdentifier)

            let reportableSyncItem = ReportableSyncItem(
                id: item.itemIdentifier.id,
                modificationTime: Date(),
                filename: filename,
                location: location,
                mimeType: item.mimeType,
                fileSize: item.documentSize??.intValue,
                operation: operation,
                state: .inProgress,
                progress: 0,
                errorDescription: nil
            )
            syncStorage.upsert(reportableSyncItem)
        }
    }

    /// Used for download and deletions.
    func didStartFileOperation(
        itemIdentifier: NSFileProviderItemIdentifier,
        operation: FileProviderOperation,
        changedFields: NSFileProviderItemFields,
        withoutLocation: Bool)
    {
        // Fetch node from MetadataDB
        let context = tower.storage.mainContext
        guard let nodeIdentifier = NodeIdentifier(rawValue: itemIdentifier.rawValue),
              let node = tower.storage.fetchNode(id: nodeIdentifier, moc: context) else {
            Log.trace("guard: node not found")
            return
        }
        Log.trace("\(node.description)")

        guard let fileInfo = nodeInformationExtractor!(node) else { return }

        Task {
            let location = withoutLocation ? "" : await shortLocation(for: itemIdentifier)

            let reportableSyncItem = ReportableSyncItem(
                id: itemIdentifier.id,
                modificationTime: Date(),
                filename: fileInfo.filename,
                location: location,
                mimeType: fileInfo.mimeType,
                fileSize: fileInfo.size,
                operation: operation,
                state: .inProgress,
                progress: 0,
                errorDescription: nil
            )
            syncStorage.upsert(reportableSyncItem)
        }
    }

    /// Used for operations other than downloads and deletions.
    func didCompleteFileOperation(
        item: NSFileProviderItem,
        possibleError: Swift.Error?,
        during operation: FileProviderOperation,
        changedFields: NSFileProviderItemFields,
        temporaryItem: NSFileProviderItem? = nil,
        withoutLocation: Bool)
    {
        guard shouldConsiderItem(item, during: operation, changedFields: changedFields) else {
            Log.trace("!shouldConsiderItem")
            return
        }
        Log.trace()

        Task {
            if let temporaryItem,
                shouldReconcileCreatedItem(item: item, possibleError: possibleError, during: operation, temporaryItem: temporaryItem) {

                resolve(
                    createdItem: item,
                    against: temporaryItem,
                    operation: operation,
                    location: ""
                )

                // Temporary workaround for DM-703 - `shortLocation` blocks on `manager.getUserVisibleURL(for:)` until
                // all downloads in a batch are completed, so we don't call it for `resolve()`, and update just the location afterwards.
                let location = withoutLocation ? "" : await shortLocation(for: item.itemIdentifier)
                syncStorage.updateLocation(identifier: item.itemIdentifier.id, to: location)
            } else {
                handleErrorOrResolve(
                    forItem: item,
                    possibleError: possibleError,
                    during: operation,
                    location: ""
                )

                let location = withoutLocation ? "" : await shortLocation(for: item.itemIdentifier)
                syncStorage.updateLocation(identifier: item.itemIdentifier.id, to: location)
            }
        }
    }

    /// Used for downloads, deletions and enumerations.
    func didCompleteFileOperation(
        itemIdentifier: NSFileProviderItemIdentifier,
        possibleError: Swift.Error?,
        during operation: FileProviderOperation,
        withoutLocation: Bool)
    {
        Task {
            let location = withoutLocation ? "" : await shortLocation(for: itemIdentifier)

            handleErrorOrResolve(
                forItemIdentifier: itemIdentifier,
                possibleError: possibleError,
                during: operation,
                location: location
            )
        }
    }

    func updateProgress(itemIdentifier: NSFileProviderItemIdentifier, progress: Progress) {
        Log.trace("\(itemIdentifier.id) \(progress.completedUnitCount)/\(progress.totalUnitCount)")
        syncStorage.updateProgress(identifier: itemIdentifier.id, progress: progress)
    }

    // MARK: Refresh action

    public func refreshStarted() {
        Log.trace()
        let item = ReportableSyncItem(
            id: ItemEnumerationObserver.enumerationSyncItemIdentifier,
            modificationTime: Date.now,
            filename: "Refreshing database...",
            location: nil,
            mimeType: nil,
            fileSize: nil,
            operation: .enumerateItems,
            state: .inProgress,
            progress: 0,
            errorDescription: nil)
        syncStorage.upsert(item)
    }

    public func refreshFinished() {
        Log.trace()
        let item = ReportableSyncItem(
            id: ItemEnumerationObserver.enumerationSyncItemIdentifier,
            modificationTime: Date.now,
            filename: "Refreshed database",
            location: nil,
            mimeType: nil,
            fileSize: nil,
            operation: .enumerateItems,
            state: .finished,
            progress: 100,
            errorDescription: nil)
        syncStorage.upsert(item)
    }

    // MARK: Clean up

    public func cleanUpOnLaunch() {
        Log.trace()
        syncStorage.cleanUpExpiredItems()
        syncStorage.cleanUpInProgressItems()
    }

    public func cleanUpOnInvalidate() {
        Log.trace()
        cleanUpOnLaunch()
    }

    func cleanUpExpiredItems() {
        Log.trace()
        syncStorage.cleanUpExpiredItems()
    }

    // MARK: - Private

    // MARK: Resolving

    private func resolve(
        createdItem: NSFileProviderItem,
        against temporaryItem: NSFileProviderItem,
        operation: FileProviderOperation,
        location: String)
    {
        Log.trace()

        let reportableItem = ReportableSyncItem(
            id: createdItem.itemIdentifier.id,
            modificationTime: Date(),
            filename: createdItem.filename,
            location: location,
            mimeType: createdItem.mimeType,
            fileSize: temporaryItem.documentSize??.intValue,
            operation: operation,
            state: .finished,
            progress: 100,
            errorDescription: nil
        )

        syncStorage.updateItem(identifiedBy: temporaryItem.itemIdentifier.id, to: reportableItem)
    }

    /// Use to handle errors from `id` when `Node` equivalent can be found in MetadataDB
    /// e.g: deleting item
    private func handleErrorOrResolve(
        forItemIdentifier itemIdentifier: NSFileProviderItemIdentifier,
        possibleError error: Swift.Error?,
        during operation: FileProviderOperation,
        location: String)
    {
        Log.trace()

        cleanUpExpiredItems()

        let context = tower.storage.mainContext

        guard let nodeIdentifier = NodeIdentifier(rawValue: itemIdentifier.rawValue),
              let node = tower.storage.fetchNode(id: nodeIdentifier, moc: context) else {
            Log.trace("guard")
            return
        }
        var filename: String!
        var mimeType: String!
        var size: Int!
        context.performAndWait {
            filename = (try? node.decryptName()) ?? "Filename decryption failed"
            mimeType = node.mimeType
            size = node.presentableNodeSize
        }
        if let error {
            handleError(
                error,
                itemIdentifier: itemIdentifier,
                filename: filename,
                mimeType: mimeType,
                size: size,
                location: location,
                operation: operation)
        } else {
            if isActingUponTrashedItem(node: node, operation: operation) {
                syncStorage.updateTrash(identifier: itemIdentifier.id)
            } else {
                let reportableSyncItem = ReportableSyncItem(
                    id: itemIdentifier.id,
                    modificationTime: Date(),
                    filename: filename,
                    location: location,
                    mimeType: mimeType,
                    fileSize: size,
                    operation: operation,
                    state: .finished,
                    progress: 100,
                    errorDescription: nil
                )
                syncStorage.upsert(reportableSyncItem)
            }
        }
    }

    /// Use to handle errors from `id` when `Node` equivalent won't be found in MetadataDB
    /// e.g: creating item, modifyItem
    private func handleErrorOrResolve(
        forItem item: NSFileProviderItem,
        possibleError error: Swift.Error?,
        during operation: FileProviderOperation,
        location: String)
    {
        Log.trace()

        cleanUpExpiredItems()

        let filename: String
        switch operation {
        // use the internal filename rather than the normalized version provided to the local filesystem
        case .move, .update:
            filename = nodeFilename(for: item)
        default:
            filename = item.filename
        }

        if let error {
            handleError(
                error,
                itemIdentifier: item.itemIdentifier,
                filename: filename,
                mimeType: item.mimeType,
                size: item.documentSize??.intValue,
                location: location,
                operation: operation)
        } else {
            let reportableSyncItem = ReportableSyncItem(
                id: item.itemIdentifier.id,
                modificationTime: Date(),
                filename: filename,
                location: location,
                mimeType: item.mimeType,
                fileSize: item.documentSize??.intValue,
                operation: operation,
                state: .finished,
                progress: 100,
                errorDescription: nil
            )
            syncStorage.upsert(reportableSyncItem)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func handleError(
        _ error: Swift.Error,
        itemIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        mimeType: String?,
        size: Int?,
        location: String,
        operation: FileProviderOperation)
    {
        let syncState = syncState(for: error)
        Log.trace("\(syncState.description) \(error.localizedDescription)")

        switch syncState {
        case .finished, .excludedFromSync, .cancelled:
            let reportableSyncItem = ReportableSyncItem(
                id: itemIdentifier.id,
                modificationTime: Date(),
                filename: filename,
                location: location,
                mimeType: mimeType,
                fileSize: size,
                operation: operation,
                state: syncState,
                progress: 100,
                errorDescription: nil
            )
            syncStorage.upsert(reportableSyncItem)

        case .errored:
            let reportableSyncItem = ReportableSyncItem(
                id: itemIdentifier.id,
                modificationTime: Date(),
                filename: filename,
                location: location,
                mimeType: mimeType,
                fileSize: size,
                operation: operation,
                state: .errored,
                progress: 0,
                errorDescription: error.localizedDescription.firstLine
            )
            syncStorage.upsert(reportableSyncItem)

        case .undefined, .inProgress:
            assert(false, "Should never happen")
        }
    }

    // MARK: Helpers

    private func shouldReconcileCreatedItem(
        item: NSFileProviderItem,
        possibleError: Swift.Error?,
        during operation: FileProviderOperation,
        temporaryItem: NSFileProviderItem) -> Bool
    {
        if possibleError != nil { return false }
        guard case .create = operation else { return false  }
        return item.itemIdentifier.id != temporaryItem.itemIdentifier.id
    }

    private func isActingUponTrashedItem(node: Node, operation: FileProviderOperation) -> Bool {
        operation == .delete && node.state == .deleted
    }

    private func shouldConsiderItem(
        _ item: NSFileProviderItem,
        during operation: FileProviderOperation,
        changedFields: NSFileProviderItemFields) -> Bool
    {
        !( (item.isFolder && operation.isModification && changedFields == .contentModificationDate) ||
           (operation.isModification && changedFields == .lastUsedDate) )
    }

    private func shortLocation(for identifier: NSFileProviderItemIdentifier) async -> String {
        do {
            // The error when fetching the root is ignored because it's not breaking the functionality
            let rootLocation = try? await url(forItem: .rootContainer)
            let location = try await url(forItem: identifier)
            let shortLocation = "/" + location.absoluteString.trimmingPrefix(rootLocation?.absoluteString ?? "/")
            let sanitizedShortLocation = shortLocation.removingPercentEncoding ?? shortLocation
            return String(sanitizedShortLocation)
        } catch {
            // we fallback on the empty string because it's more resilient than explicitely handling
            // all the possible cases in which this call can throw — and its throwing causes
            // the tray app to show wrong info to the user, which is more confusing than location missing
            return ""
        }
    }

    private func url(forItem identifier: NSFileProviderItemIdentifier) async throws -> URL {
        let url = try await manager.getUserVisibleURL(for: identifier)
        guard url.startAccessingSecurityScopedResource() else {
            fatalError("Could not open domain (failed to access URL resource)")
        }
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        return url
    }

    // swiftlint:disable:next function_parameter_count
    private func handleError(
        _ error: Swift.Error,
        itemIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        location: String,
        mimeType: String?,
        size: Int?,
        operation: FileProviderOperation)
    {
        let syncState = syncState(for: error)
        Log.trace("\(syncState.description) \(error.localizedDescription)")

        switch syncState {
        case .finished, .excludedFromSync, .cancelled:
            let reportableSyncItem = ReportableSyncItem(
                id: itemIdentifier.id,
                modificationTime: Date(),
                filename: filename,
                location: location,
                mimeType: mimeType,
                fileSize: size,
                operation: operation,
                state: syncState,
                progress: 100,
                errorDescription: nil
            )
            syncStorage.upsert(reportableSyncItem)

        case .errored:
            let reportableSyncItem = ReportableSyncItem(
                id: itemIdentifier.id,
                modificationTime: Date(),
                filename: filename,
                location: location,
                mimeType: mimeType,
                fileSize: size,
                operation: operation,
                state: .errored,
                progress: 0,
                errorDescription: error.localizedDescription.firstLine
            )
            syncStorage.upsert(reportableSyncItem)

        case .undefined, .inProgress:
            assert(false, "Should never happen")
        }
    }

    private func syncState(for error: Swift.Error) -> SyncItemState {
        switch error {
        case Errors.excludeFromSync:
            return .excludedFromSync
        case DDKError.cancellation,
            CocoaError.userCancelled,
            CancellationReason.fileProviderDeinited:
            return .cancelled
        default:
            return .errored
        }
    }

    private func nodeFilename(for item: NSFileProviderItem) -> String {
        let context = tower.storage.mainContext
        guard let nodeIdentifier = NodeIdentifier(rawValue: item.itemIdentifier.rawValue),
              let node = tower.storage.fetchNode(id: nodeIdentifier, moc: context) else {
            Log.trace("guard: node not found")
            return item.filename
        }
        Log.trace("\(node.description)")

        return nodeInformationExtractor?(node)?.filename ?? item.filename
    }
}

extension NSFileProviderItem {
    var mimeType: String? {
        if isFolder {
            return "Folder" // Returned by BE
        }
        guard let utType = contentType else {
            return nil
        }
        return MimeType(uti: utType.identifier)?.value
    }
}

extension String {
    var firstLine: String {
        return components(separatedBy: "\n").first ?? ""
    }
}
