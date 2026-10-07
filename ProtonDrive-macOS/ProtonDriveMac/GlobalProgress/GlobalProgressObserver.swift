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
import PDFileProvider

/// Owned by `ApplicationEventObserver`; consumes a `GlobalProgressSource` and updates `ApplicationState`.
@MainActor
final class GlobalProgressObserver {
    private let state: ApplicationState
    private let progressSource: any GlobalProgressSource
    private var task: Task<Void, Never>?

#if HAS_QA_FEATURES
    private(set) var qaStatusItem: GlobalProgressStatusItem?
#endif

    init(
        state: ApplicationState,
        progressSource: any GlobalProgressSource
    ) {
        self.state = state
        self.progressSource = progressSource
    }

    deinit {
        task?.cancel()
#if HAS_QA_FEATURES
        let qaStatusItem = qaStatusItem
        Task { @MainActor in
            qaStatusItem?.remove()
        }
#endif
    }

    func startObservingProgress(for domain: NSFileProviderDomain) {
        task?.cancel()
        apply(.idle)
        let progressUpdates = progressSource.makeProgressStream(for: domain)
        task = Task { [weak self] in
            for await progress in progressUpdates {
                // A cancelled consumer may already have dequeued a value.
                guard let self, !Task.isCancelled else { return }
                self.apply(progress)
            }
        }
    }

    func stopObservingProgress() {
        task?.cancel()
        task = nil
        state.globalSyncStateDescription = nil
        state.totalFilesLeftToSync = 0
#if HAS_QA_FEATURES
        qaStatusItem?.remove()
        qaStatusItem = nil
#endif
    }

    private func apply(_ progress: GlobalProgress) {
        let description = GlobalProgressDescription(progress: progress)
        state.globalSyncStateDescription = description?.fullDescription
        state.totalFilesLeftToSync = description?.remainingFileCount ?? 0
#if HAS_QA_FEATURES
        getOrCreateQaStatusItem().update(from: progress)
#endif
    }

#if HAS_QA_FEATURES
    func toggleQaStatusItemVisibility() {
        getOrCreateQaStatusItem().toggleQaStatusItemVisibility()
    }

    private func getOrCreateQaStatusItem() -> GlobalProgressStatusItem {
        if let qaStatusItem {
            return qaStatusItem
        }
        let item = GlobalProgressStatusItem()
        qaStatusItem = item
        return item
    }
#endif
}
