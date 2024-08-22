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

extension FileProviderExtension {

    // MARK: Updating items

    func forward(item: NSFileProviderItem, operation: FileProviderOperation, changedFields: NSFileProviderItemFields) {
        guard shouldConsiderItem(item, during: operation, changedFields: changedFields) else {
            return
        }
        Task { @MainActor in
            do {
                let shortLocation = try await shortLocation(for: item.itemIdentifier)
                let reportableSyncItem = ReportableSyncItem(
                    id: item.itemIdentifier.id,
                    modificationTime: Date(),
                    filename: item.filename,
                    location: shortLocation,
                    mimeType: mimeType(for: item),
                    fileSize: item.documentSize??.intValue,
                    operation: operation,
                    state: .inProgress,
                    description: nil
                )
                syncReportingController.update(item: reportableSyncItem)
            } catch {
                Log.error("Forwarding Item failed: \(error.localizedDescription)", domain: .syncing)
            }
        }
    }

    func forward(itemIdentifier: NSFileProviderItemIdentifier, operation: FileProviderOperation, changedFields: NSFileProviderItemFields) {
        // Fetch node from MetadataDB
        let context = tower.storage.mainContext
        guard let nodeIdentifier = NodeIdentifier(rawValue: itemIdentifier.rawValue),
                let node = tower.storage.fetchNode(id: nodeIdentifier, moc: context) else {
            return
        }
        Log.debug("Syncing item: \(node.description)", domain: .syncing)
        
        Task { @MainActor in
            do {
                var filename: String!
                var mimeType: String!
                var size: Int!
                context.performAndWait {
                    filename = (try? node.decryptName()) ?? "Filename decryption failed"
                    if let item = try? NodeItem(node: node) {
                        mimeType = self.mimeType(for: item)
                    } else {
                        mimeType = node.mimeType
                    }
                    size = node.size
                }
                let shortLocation = try await shortLocation(for: itemIdentifier)
                let reportableSyncItem = ReportableSyncItem(
                    id: itemIdentifier.id,
                    modificationTime: Date(),
                    filename: filename,
                    location: shortLocation,
                    mimeType: mimeType,
                    fileSize: size,
                    operation: operation,
                    state: .inProgress,
                    description: nil
                )
                syncReportingController.update(item: reportableSyncItem)
            } catch {
                Log.error("Forwarding Item failed for identifier: \(error.localizedDescription)", domain: .syncing)
            }
        }
    }

    func reconcile(item: NSFileProviderItem, possibleError: Error?, during operation: FileProviderOperation, changedFields: NSFileProviderItemFields, temporaryItem: NSFileProviderItem? = nil) {
        guard shouldConsiderItem(item, during: operation, changedFields: changedFields) else {
            return
        }
        if let temporaryItem, shouldReconcileCreatedItem(item: item, possibleError: possibleError, during: operation, temporaryItem: temporaryItem) {
            self.resolve(createdItem: item, against: temporaryItem, operation: operation)
        } else {
            self.handleErrorOrResolve(possibleError: possibleError, forItem: item, during: operation)
        }
    }

    func reconcile(itemIdentifier: NSFileProviderItemIdentifier, possibleError: Error?, during operation: FileProviderOperation) {
        self.handleErrorOrResolve(possibleError: possibleError, forItem: itemIdentifier, during: operation)
    }

    func shouldReconcileCreatedItem(item: NSFileProviderItem, possibleError: Error?, during operation: FileProviderOperation, temporaryItem: NSFileProviderItem) -> Bool {
        if possibleError != nil { return false }
        guard case .create = operation else { return false  }
        return item.itemIdentifier.id != temporaryItem.itemIdentifier.id
    }

    // MARK: Collecting errors

    /// Use to handle errors from `id` when `Node` equivalent can be found in MetadataDB
    /// e.g: deleting item
    func handleErrorOrResolve(possibleError error: Error?,
                              forItem itemIdentifier: NSFileProviderItemIdentifier,
                              during operation: FileProviderOperation) {
        cleanSyncItemsIfNeeded()
        Task { @MainActor in
            let context = tower.storage.mainContext
            guard let nodeIdentifier = NodeIdentifier(rawValue: itemIdentifier.rawValue),
                    let node = tower.storage.fetchNode(id: nodeIdentifier, moc: context) else {
                return
            }
            var filename: String!
            var mimeType: String!
            var size: Int!
            context.performAndWait {
                filename = (try? node.decryptName()) ?? "Filename decryption failed"
                mimeType = node.mimeType
                size = node.size
            }
            if let error {
                guard shouldReportError(error) else {
                    let shortLocation = try? await shortLocation(for: itemIdentifier)
                    let reportableSyncItem = ReportableSyncItem(
                        id: itemIdentifier.id,
                        modificationTime: Date(),
                        filename: filename,
                        location: shortLocation,
                        mimeType: mimeType,
                        fileSize: size,
                        operation: operation,
                        state: .finished,
                        description: nil
                    )
                    try? syncReportingController.resolve(item: reportableSyncItem)
                    return
                }

                do {
                    let shortLocation = try await shortLocation(for: itemIdentifier)
                    let reportableItem = ReportableSyncItem(
                        id: itemIdentifier.id,
                        modificationTime: Date(),
                        filename: filename,
                        location: shortLocation,
                        mimeType: mimeType,
                        fileSize: size,
                        operation: operation,
                        state: .errored,
                        description: error.localizedDescription
                    )
                    try syncReportingController.report(item: reportableItem)
                } catch is NSFileProviderError {
                    stopProcessingItem(identifier: itemIdentifier)
                } catch {
                    Log.error("Could not handle syncing error: \(error.localizedDescription)", domain: .syncing)
                }

            } else {
                if isActingUponTrashedItem(node: node, operation: operation) {
                    try syncReportingController.resolveTrash(id: itemIdentifier.id)
                } else {
                    do {
                        let shortLocation = try await shortLocation(for: itemIdentifier)
                        let reportableItem = ReportableSyncItem(
                            id: itemIdentifier.id,
                            modificationTime: Date(),
                            filename: filename,
                            location: shortLocation,
                            mimeType: mimeType,
                            fileSize: size,
                            operation: operation,
                            state: .finished,
                            description: nil
                        )
                        try syncReportingController.resolve(item: reportableItem)
                    } catch {
                        Log.error("Could not handle syncing error: \(error.localizedDescription)", domain: .syncing)
                    }
                }
            }
        }
    }

    /// Use to handle errors from `id` when `Node` equivalent won't be found in MetadataDB
    /// e.g: creating item, modifyItem
    func handleErrorOrResolve(possibleError error: Error?,
                              forItem item: NSFileProviderItem,
                              during operation: FileProviderOperation) {
        cleanSyncItemsIfNeeded()
        Task { @MainActor in
            if let error {
                guard shouldReportError(error) else {
                    let reportableItem = ReportableSyncItem(
                        id: item.itemIdentifier.id,
                        modificationTime: Date(),
                        filename: item.filename,
                        location: try await shortLocation(for: item.itemIdentifier),
                        mimeType: mimeType(for: item),
                        fileSize: item.documentSize??.intValue,
                        operation: operation,
                        state: .finished,
                        description: nil
                    )
                    try? syncReportingController.resolve(item: reportableItem)
                    return
                }

                Log.debug("FileProviderSyncError: \(error.localizedDescription)", domain: .syncing)

                do {
                    let reportableItem = ReportableSyncItem(
                        id: item.itemIdentifier.id,
                        modificationTime: Date(),
                        filename: item.filename,
                        location: try await shortLocation(for: item.itemIdentifier),
                        mimeType: mimeType(for: item),
                        fileSize: item.documentSize??.intValue,
                        operation: operation,
                        state: .errored,
                        description: error.localizedDescription
                    )
                    try? syncReportingController.report(item: reportableItem)
                } catch is NSFileProviderError {
                    stopProcessingItem(identifier: item.itemIdentifier)
                } catch {
                    Log.error("Could not handle syncing error for item: \(error.localizedDescription)", domain: .syncing)
                }
            } else {
                let reportableItem = ReportableSyncItem(
                    id: item.itemIdentifier.id,
                    modificationTime: Date(),
                    filename: item.filename,
                    location: try await shortLocation(for: item.itemIdentifier),
                    mimeType: mimeType(for: item),
                    fileSize: item.documentSize??.intValue,
                    operation: operation,
                    state: .finished,
                    description: nil
                )
                try syncReportingController.resolve(item: reportableItem)
            }
        }
    }

    private func resolve(createdItem: NSFileProviderItem, against temporaryItem: NSFileProviderItem, operation: FileProviderOperation) {
        Task { @MainActor in
            do {
                let reportableItem = ReportableSyncItem(
                    id: createdItem.itemIdentifier.id,
                    modificationTime: Date(),
                    filename: createdItem.filename,
                    // We need temporaryItem.itemIdentifier to get userVisibleURL
                    location: try await shortLocation(for: temporaryItem.itemIdentifier),
                    mimeType: mimeType(for: createdItem),
                    fileSize: temporaryItem.documentSize??.intValue,
                    operation: operation,
                    state: .finished,
                    description: nil
                )
                try syncReportingController.updateTemporaryItem(id: temporaryItem.itemIdentifier.id, with: reportableItem)
            } catch {
                Log.error("Could not resolve createdItem against temporary one", domain: .syncing)
            }
        }
    }

    // MARK: - Clean up

    func cleanUpSyncStorageAfterInvalidate() {
        syncReportingController.cleanSyncingItems()
    }

    private func cleanSyncItemsIfNeeded() {
        try? syncReportingController.cleanSyncItems(olderThan: syncStorage.oldItemsRelativeDate)
    }

    private func stopProcessingItem(identifier: NSFileProviderItemIdentifier) {
        guard let storage = tower.syncStorage else { return }
        do {
            try storage.resolveItem(id: identifier.id, in: storage.mainContext)
        } catch {
            Log.debug("Failed when stop processing item: \(error.localizedDescription)", domain: .syncing)
        }
    }

    private func isActingUponTrashedItem(node: Node, operation: FileProviderOperation) -> Bool {
        operation == .delete && node.state == .deleted
    }

    private func shouldReportError(_ error: Error) -> Bool {
        switch error {
        case Errors.excludeFromSync:
            return false
        default:
            return true
        }
    }

    private func shouldConsiderItem(_ item: NSFileProviderItem, during operation: FileProviderOperation, changedFields: NSFileProviderItemFields) -> Bool {
        !( (item.isFolder && operation == .modify && changedFields == .contentModificationDate) ||
           (operation == .modify && changedFields == .lastUsedDate) )
    }

    private func mimeType(for item: NSFileProviderItem) -> String? {
        if item.isFolder {
            return "Folder" // Returned by BE
        }
        guard let utType = item.contentType else {
            return nil
        }
        return MimeType(uti: utType.identifier)?.value
    }

    private func shortLocation(for identifier: NSFileProviderItemIdentifier) async throws -> String {
        // the error when fetching the root is ignored because it's not breaking the functionality
        let rootLocation = try? await url(forItem: .rootContainer)
        let location = try await url(forItem: identifier)
        let shortLocation = "/" + location.absoluteString.trimmingPrefix(rootLocation?.absoluteString ?? "/")
        let sanitizedShortLocation = shortLocation.removingPercentEncoding ?? shortLocation
        return String(sanitizedShortLocation)
    }

    private func url(forItem identifier: NSFileProviderItemIdentifier) async throws -> URL {
        do {
            let url = try await manager.getUserVisibleURL(for: identifier)
            guard url.startAccessingSecurityScopedResource() else {
                fatalError("Could not open domain (failed to access URL resource)")
            }
            defer {
                url.stopAccessingSecurityScopedResource()
            }
            return url
        } catch {
            throw error
        }
    }
}
