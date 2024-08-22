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

import Combine
import PDCore
import AppKit
import PDFileProvider

final class SyncErrorViewModel: ObservableObject {

    typealias Update = ReportableSyncItem

    private let storageManager: SyncStorageManager

    private let closeHandler: @MainActor () -> Void

    let baseURL: URL

    private let communicationService: CoreDataCommunicationService<SyncItem>?
    private let updates: AsyncStream<EntityWithChangeType<SyncItem>>?
    private var updatesTask: Task<(), Never>?

    @Published var errors: [ReportableSyncItem] = []

    init(storageManager: SyncStorageManager, 
         communicationService: CoreDataCommunicationService<SyncItem>?, 
         baseURL: URL,
         closeHandler: @MainActor @escaping () -> Void) {
        self.baseURL = baseURL
        self.closeHandler = closeHandler
        self.storageManager = storageManager
        self.communicationService = communicationService
        self.updates = communicationService?.updates
        observeUpdates()
    }

    func closeButtonTapped() {
        Task { @MainActor in
            self.closeHandler()
        }
    }

    private func reportableItem(from item: SyncItem) async -> ReportableSyncItem? {
        await communicationService?.moc.perform {
            guard item.filename != nil else {
                return nil
            }
            return ReportableSyncItem(item: item)
        }
    }

    private func observeUpdates() {
        guard let updates else {
            return
        }

        updatesTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                switch update {
                case .delete(let objectIdentifier):
                    await MainActor.run { [weak self] in
                        self?.errors.removeAll(where: { $0.objectIdentifier == objectIdentifier })
                    }
                    
                case .insert(let syncItem):
                    guard let reportableError = await self?.reportableItem(from: syncItem) else { continue }
                    guard .errored == reportableError.state else { continue }
                    await MainActor.run { [weak self] in
                        self?.errors.append(reportableError)
                    }

                case .update(let syncItem):
                    guard let reportableError = await self?.reportableItem(from: syncItem) else { continue }
                    if .errored == reportableError.state {
                        if let index = self?.errors.firstIndex(
                            where: { $0.objectIdentifier == syncItem.objectIdentifier }
                        ) {
                            await MainActor.run { [weak self] in
                                self?.errors[index] = reportableError
                            }
                        } else {
                            await MainActor.run { [weak self] in
                                self?.errors.append(reportableError)
                            }
                        }
                    } else {
                        if let index = self?.errors.firstIndex(
                            where: { $0.objectIdentifier == syncItem.objectIdentifier }
                        ) {
                            await MainActor.run { [weak self] in
                                _ = self?.errors.remove(at: index)
                            }
                        }
                    }

                @unknown default:
                    Log.error("Unknown case for NSPersistentHistoryChangeType", domain: .ipc)
                }
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }
}
