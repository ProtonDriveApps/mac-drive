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

#if HAS_QA_FEATURES

import AppKit
import PDCore
import PDFileProvider

/// QA-only status-bar display of directional progress, owned and updated by `GlobalProgressObserver`.
@MainActor
class GlobalProgressStatusItem {
    var progressStatusItem: NSStatusItem!

    init() {
        self.makeStatusItem()
    }
    
    public func remove() {
        NSStatusBar.system.removeStatusItem(progressStatusItem)
    }

    private func makeStatusItem() {
        self.progressStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.progressStatusItem.button?.font = NSFont.labelFont(ofSize: NSFont.labelFontSize)
        refresh()
    }

    func toggleQaStatusItemVisibility() {
        let shouldHideStatusItem = !UserDefaults.standard.bool(forKey: QASettingsConstants.globalProgressStatusMenuEnabled)
        UserDefaults.standard.set(shouldHideStatusItem, forKey: QASettingsConstants.globalProgressStatusMenuEnabled)
        refresh()
    }

    func update(from progress: GlobalProgress) {
        guard UserDefaults.standard.bool(forKey: QASettingsConstants.globalProgressStatusMenuEnabled) else {
            progressStatusItem.button?.title = " "
            progressStatusItem.button?.sizeToFit()
            return
        }

        guard case .active(let activeTransfer) = progress else {
            progressStatusItem.button?.title = " "
            progressStatusItem.button?.sizeToFit()
            return
        }

        let descriptions: [String]
        switch activeTransfer {
        case .upload(let transferProgress):
            descriptions = [makeDirectionalDescription(transferProgress, direction: "⬆️")]
        case .download(let transferProgress):
            descriptions = [makeDirectionalDescription(transferProgress, direction: "⬇️")]
        case .bidirectional(let upload, let download):
            descriptions = [
                makeDirectionalDescription(download, direction: "⬇️"),
                makeDirectionalDescription(upload, direction: "⬆️"),
            ]
        }
        progressStatusItem.button?.title = descriptions.joined(separator: " | ")
        progressStatusItem.button?.sizeToFit()
    }

    private func makeDirectionalDescription(
        _ transferProgress: GlobalProgress.ActiveTransfer.TransferProgress,
        direction: String
    ) -> String {
        let byteInfo = "\(transferProgress.completedByteCount.formattedFileSize) of \(transferProgress.totalByteCount.formattedFileSize)"
        let percentage = String(format: "(%.2f%%)", transferProgress.fractionCompleted * 100)
        switch transferProgress {
        case .counted(let counted):
            let currentFileIndex = min(counted.completedFileCount + 1, counted.totalFileCount)
            let countInfo = counted.totalFileCount == 1
                ? "1 file"
                : "\(currentFileIndex) of \(counted.totalFileCount) files"
            return "\(direction) \(countInfo): \(byteInfo) \(percentage)"
        case .uncounted:
            return "\(direction) \(byteInfo) \(percentage)"
        }
    }

    func refresh() {
        update(from: .idle)
    }
}

#endif
