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

enum GlobalProgressDescription {

    case upload(GlobalSyncState)
    case download(GlobalSyncState)
    case both(GlobalSyncState)

    init?(downloadProgress: Progress?, uploadProgress: Progress?) {
        let downloadState = GlobalSyncState(progress: downloadProgress)
        let uploadState = GlobalSyncState(progress: uploadProgress)

        switch (downloadState, uploadState) {
        case (nil, nil):
            return nil
        case(let dl, nil):
            self = .download(dl!)
        case (nil, let ul):
            self = .upload(ul!)
        case (let dl, let ul):
            self = .both(GlobalSyncState(byMerging: dl!, with: ul!))
        }
    }

    var fullDescription: String {
        return "\(direction) \(formattedFileCount) (\(formattedByteCount)) \(formattedPercentage)"
    }

    var direction: String {
        switch self {
        case .upload:
            "Uploading"
        case .download:
            "Downloading"
        case .both:
            "Syncing"
        }
    }

    var syncState: GlobalSyncState {
        switch self {
        case .upload(let globalSyncState):
            globalSyncState
        case .download(let globalSyncState):
            globalSyncState
        case .both(let globalSyncState):
            globalSyncState
        }
    }

    var formattedPercentage: String {
        let currentState = self.syncState

        var percentText: String
        let percentFormat = "%.0f%%"
        percentText = String(format: percentFormat, currentState.fractionCompleted * 100)
        if currentState.fractionCompleted < 1, percentText.starts(with: "100") {
            // We don't want to show 100% unless we really are at the end.
            percentText = "99%"
        }

        return percentText
    }

    var formattedByteCount: String {
        let doneBytesText = Int(syncState.completedByteCount).formattedFileSize
        let toDoBytesText = Int(syncState.totalByteCount).formattedFileSize
        let byteCountText = "\(doneBytesText) of \(toDoBytesText)"

        return byteCountText
    }

    var formattedFileCount: String {
        let currentState = syncState

        // For a single file it makes no sense to do "x of y" files.
        if currentState.totalFileCount == 1 {
            return "\(NumberFormatter.localizedString(from: 1, number: .decimal)) file"
        }

        let currentFile = NumberFormatter.localizedString(from: currentState.currentFileIndex as NSNumber, number: .decimal)
        let totalFiles = NumberFormatter.localizedString(from: currentState.totalFileCount as NSNumber, number: .decimal)
        return "file \(currentFile) of \(totalFiles)"
    }

    var totalFileCount: Int {
        syncState.totalFileCount - syncState.currentFileIndex
    }
}

extension Int {
    var formattedFileSize: String {
        let GB = 1_073_741_824
        let MB = 1_048_576
        let kB = 1024

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
