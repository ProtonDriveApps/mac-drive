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
import PDFileProvider

/// Formats active progress for `GlobalProgressObserver` to apply to application presentation.
struct GlobalProgressDescription {
    private let activeTransfer: GlobalProgress.ActiveTransfer
    private let locale: Locale

    init?(progress: GlobalProgress, locale: Locale = .current) {
        guard case .active(let activeTransfer) = progress else { return nil }
        self.activeTransfer = activeTransfer
        self.locale = locale
    }

    var fullDescription: String {
        guard let fileCount = formattedFileCount else {
            return direction
        }
        return "\(direction) \(fileCount) (\(formattedByteCount)) \(formattedPercentage)"
    }

    var direction: String {
        switch activeTransfer {
        case .upload:
            "Uploading"
        case .download:
            "Downloading"
        case .bidirectional:
            "Syncing"
        }
    }

    var formattedPercentage: String {
        var percentText = String(format: "%.2f%%", activeTransfer.fractionCompleted * 100)
        if percentText.starts(with: "100") {
            percentText = "99%"
        }
        return percentText
    }

    var formattedByteCount: String {
        let doneBytesText = activeTransfer.completedByteCount.formattedFileSize
        let toDoBytesText = activeTransfer.totalByteCount.formattedFileSize
        return "\(doneBytesText) of \(toDoBytesText)"
    }

    var formattedFileCount: String? {
        guard let totalFileCount = activeTransfer.totalFileCount,
              let currentFileIndex = activeTransfer.currentFileIndex else {
            return nil
        }
        if totalFileCount == 1 {
            return "\(formattedDecimal(1)) file"
        }
        let currentFile = formattedDecimal(currentFileIndex)
        let totalFiles = formattedDecimal(totalFileCount)
        return "file \(currentFile) of \(totalFiles)"
    }

    private func formattedDecimal(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: number as NSNumber) ?? "\(number)"
    }

    var remainingFileCount: Int {
        max(activeTransfer.knownRemainingFileCount, activeTransfer.containsUncounted ? 1 : 0)
    }
}

extension Int {
    var formattedFileSize: String {
        Int64(self).formattedFileSize
    }
}

extension Int64 {
    var formattedFileSize: String {
        let GB: Int64 = 1_073_741_824
        let MB: Int64 = 1_048_576
        let kB: Int64 = 1024

        return if self > GB {
            "\(self / GB) GB"
        } else if self > MB {
            "\(self / MB) MB"
        } else if self > kB {
            "\(self / kB) kB"
        } else if self == 0 {
            "0"
        } else if self == 1 {
            "\(self) byte"
        } else {
            "\(self) bytes"
        }
    }
}
