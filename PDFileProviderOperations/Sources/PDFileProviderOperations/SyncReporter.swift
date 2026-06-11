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

@preconcurrency import PDCore
import FileProvider
import PDFileProvider
import ProtonDriveSDK

// Tuple used to thread-safely store some information about the node
typealias NodeInformationExtractor = (Node) -> (filename: String, mimeType: String, size: Int)?

public final class SyncStateMapper {
    public init() {}

    public func syncState(for error: Swift.Error) -> SyncItemState {
        switch error {
        case Errors.excludeFromSync:
            return .excludedFromSync
        case CancellationReason.networkOffline:
            return .paused
        case let error as any CancellationIdentifiableError where error.isCancellationError:
            return .cancelled
        case CocoaError.userCancelled, CancellationReason.fileProviderDeinited:
            return .cancelled
        default:
            return .errored
        }
    }
}

public final class NetworkOfflineDetector {
    private let connectionStateResource: ConnectionStateResource

    public init(connectionStateResource: ConnectionStateResource) {
        self.connectionStateResource = connectionStateResource
    }

    public func isLikelyOffline(progress: Progress, error: Error? = nil) -> Bool {
        if progress.cancellationReason == .networkOffline {
            return true
        }
        if connectionStateResource.currentState == .unreachable {
            return true
        }
        if let sdkError = error as? ProtonDriveSDKError, sdkError.isLikelyOffline {
            return true
        }
        return false
    }
}

public class SyncReporter {
    private let tower: Tower
    private let manager: NSFileProviderManager
    private let syncStateMapper = SyncStateMapper()
    private let itemTasksLock = NSLock()
    private var itemTasks: [String: Task<Void, Never>] = [:]

    /// Enqueues an async operation for the given item, guaranteeing that operations
    /// for the same `itemId` execute in the order they were enqueued.
    /// Operations for different items run concurrently.
    private func enqueue(for itemId: String, operation: @escaping @Sendable () async -> Void) {
        itemTasksLock.lock()
        let previous = itemTasks[itemId]
        let newTask = Task {
            await previous?.value
            await operation()
        }
        itemTasks[itemId] = newTask
        itemTasksLock.unlock()
    }

    private var syncStorage: SyncStorageManager {
        tower.syncStorage ?? SyncStorageManager(suite: .group(named: Constants.appGroup))
    }

    // must be called within NSManagedObject
    var nodeInformationExtractor: NodeInformationExtractor?

    public init(
        tower: Tower,
        manager: NSFileProviderManager
    ) {
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

        enqueue(for: item.itemIdentifier.id) { [self] in
            let filename: String
            switch operation {
            // use the internal filename rather than the normalized version provided to the local filesystem
            case .move, .update:
                filename = await nodeFilename(for: item)
            default:
                filename = item.filename
            }

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
            await syncStorage.backgroundContextPool.withContext { context in
                syncStorage.upsert(reportableSyncItem, in: context)
            }
        }
    }

    /// Used for download and deletions.
    func didStartFileOperation(
        itemIdentifier: NSFileProviderItemIdentifier,
        operation: FileProviderOperation,
        changedFields: NSFileProviderItemFields,
        withoutLocation: Bool)
    {
        enqueue(for: itemIdentifier.id) { [self] in
            guard let fileInfo = await nodeMetadata(for: itemIdentifier) else { return }

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
            await syncStorage.backgroundContextPool.withContext { context in
                syncStorage.upsert(reportableSyncItem, in: context)
            }
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

        enqueue(for: item.itemIdentifier.id) { [self] in
            if let temporaryItem,
                shouldReconcileCreatedItem(item: item, possibleError: possibleError, during: operation, temporaryItem: temporaryItem) {

                await resolve(
                    createdItem: item,
                    against: temporaryItem,
                    operation: operation,
                    location: ""
                )

                // Temporary workaround for DM-703 - `shortLocation` blocks on `manager.getUserVisibleURL(for:)` until
                // all downloads in a batch are completed, so we don't call it for `resolve()`, and update just the location afterwards.
                let location = withoutLocation ? "" : await shortLocation(for: item.itemIdentifier)
                await syncStorage.backgroundContextPool.withContext { context in
                    syncStorage.updateLocation(identifier: item.itemIdentifier.id, to: location, in: context)
                }
            } else {
                await handleErrorOrResolve(
                    forItem: item,
                    possibleError: possibleError,
                    during: operation,
                    location: ""
                )

                let location = withoutLocation ? "" : await shortLocation(for: item.itemIdentifier)
                await syncStorage.backgroundContextPool.withContext { context in
                    syncStorage.updateLocation(identifier: item.itemIdentifier.id, to: location, in: context)
                }
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
        enqueue(for: itemIdentifier.id) { [self] in
            let location = withoutLocation ? "" : await shortLocation(for: itemIdentifier)

            await handleErrorOrResolve(
                forItemIdentifier: itemIdentifier,
                possibleError: possibleError,
                during: operation,
                location: location
            )
        }
    }

    func updateProgress(itemIdentifier: NSFileProviderItemIdentifier, progress: Progress?) {
        if let progress {
            Log.trace("\(itemIdentifier.id) \(progress.completedUnitCount)/\(progress.totalUnitCount)")
        }
        enqueue(for: itemIdentifier.id) { [self] in
            guard let progress else { return }
            await syncStorage.backgroundContextPool.withContext { moc in
                syncStorage.updateProgress(identifier: itemIdentifier.id, progress: progress, in: moc)
            }
        }
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
        Task {
            await syncStorage.backgroundContextPool.withContext { context in
                syncStorage.upsert(item, in: context)
            }
        }
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
        Task {
            await syncStorage.backgroundContextPool.withContext { context in
                syncStorage.upsert(item, in: context)
            }
        }
    }

    // MARK: Clean up

    public func cleanUpOnLaunch() async {
        Log.trace()
        await syncStorage.cleanUpExpiredItems()
        await syncStorage.cleanUpInProgressItems()
    }

    public func cleanUpOnInvalidate() async {
        Log.trace()
        await cleanUpOnLaunch()
    }

    func cleanUpExpiredItems() async {
        Log.trace()
        await syncStorage.cleanUpExpiredItems()
    }

    // MARK: - Private

    // MARK: Resolving

    private func resolve(
        createdItem: NSFileProviderItem,
        against temporaryItem: NSFileProviderItem,
        operation: FileProviderOperation,
        location: String
    ) async {
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
        await syncStorage.backgroundContextPool.withContext { context in
            syncStorage.updateItem(identifiedBy: temporaryItem.itemIdentifier.id, to: reportableItem, in: context)
        }
    }

    /// Use to handle errors from `id` when `Node` equivalent can be found in MetadataDB
    /// e.g: deleting item
    private func handleErrorOrResolve(
        forItemIdentifier itemIdentifier: NSFileProviderItemIdentifier,
        possibleError error: Swift.Error?,
        during operation: FileProviderOperation,
        location: String
    ) async {
        Log.trace()

        await cleanUpExpiredItems()

        let result: (String, String, Int, Bool)? = await tower.storage.backgroundContextPool.withContext { context in
            guard let nodeIdentifier = NodeIdentifier(rawValue: itemIdentifier.rawValue),
                  let node = tower.storage.fetchNode(id: nodeIdentifier, moc: context) else {
                Log.trace("guard")
                return nil
            }
            return await context.perform {
                let filename = (try? node.decryptName()) ?? "Filename decryption failed"
                let mimeType = node.mimeType
                let size = node.presentableNodeSize
                let isDeleted = node.isDeleted
                return (filename, mimeType, size, isDeleted)
            }
        }
        guard let (filename, mimeType, size, isDeleted) = result else { return }


        if let error {
            await handleError(
                error,
                itemIdentifier: itemIdentifier,
                filename: filename,
                mimeType: mimeType,
                size: size,
                location: location,
                operation: operation)
        } else {
            if isActingUponTrashedItem(isDeleted: isDeleted, operation: operation) {
                await syncStorage.backgroundContextPool.withContext { context in
                    syncStorage.updateTrash(identifier: itemIdentifier.id, in: context)
                }
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
                await syncStorage.backgroundContextPool.withContext { context in
                    syncStorage.upsert(reportableSyncItem, in: context)
                }
            }
        }
    }

    /// Use to handle errors from `id` when `Node` equivalent won't be found in MetadataDB
    /// e.g: creating item, modifyItem
    private func handleErrorOrResolve(
        forItem item: NSFileProviderItem,
        possibleError error: Swift.Error?,
        during operation: FileProviderOperation,
        location: String
    ) async {
        Log.trace()

        await cleanUpExpiredItems()

        let filename: String
        switch operation {
        // use the internal filename rather than the normalized version provided to the local filesystem
        case .move, .update:
            filename = await nodeFilename(for: item)
        default:
            filename = item.filename
        }

        if let error {
            await handleError(
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
            await syncStorage.backgroundContextPool.withContext { context in
                syncStorage.upsert(reportableSyncItem, in: context)
            }
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
        operation: FileProviderOperation
    ) async {
        let syncState = syncStateMapper.syncState(for: error)
        Log.trace("\(syncState.description) \(error.localizedDescription)")

        switch syncState {
        case .finished, .excludedFromSync, .cancelled, .paused:
            let reportableSyncItem = ReportableSyncItem(
                id: itemIdentifier.id,
                modificationTime: Date(),
                filename: filename,
                location: location,
                mimeType: mimeType,
                fileSize: size,
                operation: operation,
                state: syncState,
                progress: syncState == .paused ? 0 : 100,
                errorDescription: nil
            )
            await syncStorage.backgroundContextPool.withContext { context in
                syncStorage.upsert(reportableSyncItem, in: context)
            }

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
            await syncStorage.backgroundContextPool.withContext { context in
                syncStorage.upsert(reportableSyncItem, in: context)
            }

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

    private func isActingUponTrashedItem(isDeleted: Bool, operation: FileProviderOperation) -> Bool {
        operation == .delete && isDeleted
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
        operation: FileProviderOperation
    ) async {
        let syncState = syncStateMapper.syncState(for: error)
        Log.trace("\(syncState.description) \(error.localizedDescription)")

        switch syncState {
        case .finished, .excludedFromSync, .cancelled, .paused:
            let reportableSyncItem = ReportableSyncItem(
                id: itemIdentifier.id,
                modificationTime: Date(),
                filename: filename,
                location: location,
                mimeType: mimeType,
                fileSize: size,
                operation: operation,
                state: syncState,
                progress: syncState == .paused ? 0 : 100,
                errorDescription: nil
            )
            await syncStorage.backgroundContextPool.withContext { context in
                syncStorage.upsert(reportableSyncItem, in: context)
            }

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
            await syncStorage.backgroundContextPool.withContext { context in
                syncStorage.upsert(reportableSyncItem, in: context)
            }

        case .undefined, .inProgress:
            assert(false, "Should never happen")
        }
    }

    private func nodeMetadata(
        for itemIdentifier: NSFileProviderItemIdentifier
    ) async -> (filename: String, mimeType: String, size: Int)? {
        guard let nodeInformationExtractor else { return nil }
        return await tower.storage.backgroundContextPool.withContext { context in
            guard let nodeIdentifier = NodeIdentifier(rawValue: itemIdentifier.rawValue),
                  let node = tower.storage.fetchNode(id: nodeIdentifier, moc: context) else {
                Log.trace("guard: node not found")
                return nil
            }

            return await context.perform {
                Log.trace("\(node.description)")
                return nodeInformationExtractor(node)
            }
        }
    }

    private func nodeFilename(for item: NSFileProviderItem) async -> String {
        await nodeMetadata(for: item.itemIdentifier)?.filename ?? item.filename
    }
}

protocol CancellationIdentifiableError where Self: Error {
    var isCancellationError: Bool { get }
}

extension ProtonDriveSDKError: CancellationIdentifiableError {
    var isCancellationError: Bool {
        guard case .successfulCancellation = domain else { return false }
        return true
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
        return MimeType(utType: utType)?.value
    }
}

extension String {
    var firstLine: String {
        return components(separatedBy: "\n").first ?? ""
    }
}
