// Copyright (c) 2026 Proton AG
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
import PDFileProvider

/// Converts Foundation progress pairs into domain values for `FoundationProgressProvider`.
protocol GlobalProgressNormalizer {
    func normalize(
        downloadProgress: Progress,
        uploadProgress: Progress
    ) -> GlobalProgress
}

/// Normalizes Foundation counts and completion flags into valid `GlobalProgress` values for the provider.
final class FoundationGlobalProgressNormalizer: GlobalProgressNormalizer {
    typealias TransferProgress = GlobalProgress.ActiveTransfer.TransferProgress

    func normalize(
        downloadProgress: Progress,
        uploadProgress: Progress
    ) -> GlobalProgress {
        let upload = normalize(progress: uploadProgress)
        let download = normalize(progress: downloadProgress)

        switch (upload, download) {
        case (nil, nil):
            return .idle
        case (.some(let upload), nil):
            return .active(.upload(upload))
        case (nil, .some(let download)):
            return .active(.download(download))
        case (.some(let upload), .some(let download)):
            return .active(.bidirectional(upload: upload, download: download))
        }
    }

    private func normalize(progress: Progress) -> TransferProgress? {
        guard !progress.isFinished, !progress.isCancelled else { return nil }

        let totalFileCount = progress.fileTotalCount
        let completedFileCount = progress.fileCompletedCount
        let totalByteCount = progress.totalUnitCount
        let completedByteCount = max(progress.completedUnitCount, 0)

        if let totalFileCount, totalFileCount > 0 {
            let completedFileCount = max(completedFileCount ?? 0, 0)
            guard completedFileCount < totalFileCount else { return nil }

            if totalByteCount == 0, completedByteCount == 0 {
                return TransferProgress.Counted(
                    totalFileCount: totalFileCount,
                    completedFileCount: completedFileCount,
                    totalByteCount: totalByteCount,
                    completedByteCount: completedByteCount
                ).map(TransferProgress.counted)
            }

            guard totalByteCount > 0, completedByteCount < totalByteCount else {
                return nil
            }
            return TransferProgress.Counted(
                totalFileCount: totalFileCount,
                completedFileCount: completedFileCount,
                totalByteCount: totalByteCount,
                completedByteCount: completedByteCount
            ).map(TransferProgress.counted)
        }

        guard totalByteCount > 0, completedByteCount < totalByteCount else {
            return nil
        }
        return TransferProgress.Uncounted(
            totalByteCount: totalByteCount,
            completedByteCount: completedByteCount
        ).map(TransferProgress.uncounted)
    }
}
