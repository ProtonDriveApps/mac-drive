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

/// Stores information from the FileProvider about global progress.
struct GlobalSyncState {
    let totalFileCount: Int
    let completedFileCount: Int
    let fractionCompleted: Double
    let totalByteCount: Int64
    let completedByteCount: Int64
    /// This is the '7' in "7 of 33 files" part of the text and indicates what file its currently doing, not how many completed files there are.
    let currentFileIndex: Int

    init?(progress: Progress?) {
        guard let progress,
              !progress.isFinished,
              progress.fileTotalCount ?? 0 != 0 else {
            return nil
        }

        totalFileCount = progress.fileTotalCount ?? 0
        guard totalFileCount != 0 else { return nil }
        completedFileCount = progress.fileCompletedCount ?? 0
        currentFileIndex = completedFileCount + 1
        totalByteCount = progress.totalUnitCount
        completedByteCount = progress.completedUnitCount
        fractionCompleted = progress.fractionCompleted
    }

    init(byMerging a: GlobalSyncState, with b: GlobalSyncState) {
        totalFileCount = a.totalFileCount + b.totalFileCount
        completedFileCount = a.completedFileCount + b.completedFileCount
        currentFileIndex = a.currentFileIndex + b.currentFileIndex
        totalByteCount = a.totalByteCount + b.totalByteCount
        completedByteCount = a.completedByteCount + b.completedByteCount
        fractionCompleted = Double(completedByteCount) / Double(totalByteCount)
    }
}
