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

import Foundation
import PDCore
import AppKit

/// Observes updates to the File Provider's global progress and propagates them to the `state` object.
/// See more: https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/globalprogress(for:)
class GlobalProgressObserver {
    private var state: ApplicationState

    private var globalDownloadProgress: Progress?
    private var globalUploadProgress: Progress?
    private var globalProgressObservers: [NSKeyValueObservation] = []

    private let domainOperationsService: DomainOperationsService

    // Debug only code to show the current download/upload state in the menu bar.
    // This is independent from the code that shows the real state in statusItem's menu.
#if HAS_QA_FEATURES
    private var statusItem: GlobalProgressStatusItem

#endif

    init(state: ApplicationState, domainOperationsService: DomainOperationsService) async {
        Log.trace()
        self.state = state
        self.domainOperationsService = domainOperationsService
#if HAS_QA_FEATURES
        self.statusItem = await GlobalProgressStatusItem()
#endif
    }

    deinit {
        Log.trace()
        stopMonitoring()
    }

    func startMonitoring() {
        Log.trace()
        // Configure the global progress observers
        globalDownloadProgress = domainOperationsService.globalProgress(for: .downloading)
        globalUploadProgress = domainOperationsService.globalProgress(for: .uploading)
        for progress in [globalDownloadProgress, globalUploadProgress] {
            guard let progress else {
                continue
            }
            var observer = progress.observe(\.description) { progress, change in
                Log.trace("description")
                self.didUpdateGlobalProgress()
            }
            globalProgressObservers.append(observer)

            observer = progress.observe(\.localizedAdditionalDescription) { progress, change in
                Log.trace("localizedAdditionalDescription")
                self.didUpdateGlobalProgress()
            }
            globalProgressObservers.append(observer)

            observer = progress.observe(\.fractionCompleted) { progress, change in
                Log.trace("fractionCompleted")
                self.didUpdateGlobalProgress()
            }
            globalProgressObservers.append(observer)
        }
    }

    func stopMonitoring() {
        globalProgressObservers.forEach { $0.invalidate() }
        globalProgressObservers.removeAll()
        globalDownloadProgress = nil
        globalUploadProgress = nil
    }

#if HAS_QA_FEATURES
    func toggleGlobalProgressStatusItem() async {
        await statusItem.toggleGlobalProgressStatusItem()
    }
#endif

    private func didUpdateGlobalProgress() {
        guard let globalProgressDescription = GlobalProgressDescription(
            downloadProgress: self.globalDownloadProgress,
            uploadProgress: self.globalUploadProgress) else {

            state.globalSyncStateDescription = "Synced"
            state.totalFilesLeftToSync = 0
            return
        }

        state.globalSyncStateDescription = globalProgressDescription.fullDescription
        state.totalFilesLeftToSync = globalProgressDescription.totalFileCount

#if HAS_QA_FEATURES
        DispatchQueue.main.async {
            self.statusItem
                .updateProgress(downloadProgress: self.globalDownloadProgress,
                                uploadProgress: self.globalUploadProgress)
        }
#endif
    }
    }
