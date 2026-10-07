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

/// Validated transfer state shared across processes, without connection or wire-format details.
public enum GlobalProgress: Equatable, Sendable {
    case idle
    /// Uploads or downloads are in progress, with known or unknown file counts.
    case active(ActiveTransfer)

    /// The active directions and their combined progress within `GlobalProgress`.
    public enum ActiveTransfer: Equatable, Sendable {
        case upload(TransferProgress)
        case download(TransferProgress)
        case bidirectional(
            upload: TransferProgress,
            download: TransferProgress
        )

        /// Progress for one direction, distinguishing known file counts from byte-only progress.
        public enum TransferProgress: Equatable, Sendable {
            /// File counts are known; byte totals may not be available yet.
            case counted(Counted)
            /// Byte progress is available, but file counts are unknown.
            case uncounted(Uncounted)

            /// An unfinished transfer with known file counts and optional byte totals, represented by zero when unknown.
            public struct Counted: Equatable, Sendable {
                public let totalFileCount: Int
                public let completedFileCount: Int
                public let totalByteCount: Int64
                public let completedByteCount: Int64

                public init?(
                    totalFileCount: Int,
                    completedFileCount: Int,
                    totalByteCount: Int64,
                    completedByteCount: Int64
                ) {
                    guard totalFileCount > 0,
                          completedFileCount >= 0,
                          completedFileCount < totalFileCount,
                          totalByteCount >= 0,
                          completedByteCount >= 0,
                          (totalByteCount == 0 && completedByteCount == 0) ||
                            (totalByteCount > 0 && completedByteCount < totalByteCount) else {
                        return nil
                    }
                    self.totalFileCount = totalFileCount
                    self.completedFileCount = completedFileCount
                    self.totalByteCount = totalByteCount
                    self.completedByteCount = completedByteCount
                }
            }

            /// An unfinished transfer with byte progress but no known file counts.
            public struct Uncounted: Equatable, Sendable {
                public let totalByteCount: Int64
                public let completedByteCount: Int64

                public init?(
                    totalByteCount: Int64,
                    completedByteCount: Int64
                ) {
                    guard totalByteCount > 0,
                          completedByteCount >= 0,
                          completedByteCount < totalByteCount else {
                        return nil
                    }
                    self.totalByteCount = totalByteCount
                    self.completedByteCount = completedByteCount
                }
            }

            public var totalByteCount: Int64 {
                byteCounts.total
            }

            public var completedByteCount: Int64 {
                byteCounts.completed
            }

            private var byteCounts: (total: Int64, completed: Int64) {
                switch self {
                case .counted(let progress):
                    (progress.totalByteCount, progress.completedByteCount)
                case .uncounted(let progress):
                    (progress.totalByteCount, progress.completedByteCount)
                }
            }

            public var fractionCompleted: Double {
                fraction(completed: completedByteCount, total: totalByteCount)
            }

            public var remainingFileCount: Int? {
                switch self {
                case .counted(let progress):
                    progress.totalFileCount - progress.completedFileCount
                case .uncounted:
                    nil
                }
            }
        }

        public var totalByteCount: Int64 {
            transfers.reduce(0) { saturatingAdd($0, $1.totalByteCount) }
        }

        public var completedByteCount: Int64 {
            transfers.reduce(0) { saturatingAdd($0, $1.completedByteCount) }
        }

        public var fractionCompleted: Double {
            let total = transfers.reduce(0.0) { $0 + Double($1.totalByteCount) }
            let completed = transfers.reduce(0.0) { $0 + Double($1.completedByteCount) }
            return fraction(completed: completed, total: total)
        }

        public var totalFileCount: Int? {
            countedTransfers?.reduce(0) { saturatingAdd($0, $1.totalFileCount) }
        }

        public var completedFileCount: Int? {
            countedTransfers?.reduce(0) { saturatingAdd($0, $1.completedFileCount) }
        }

        /// The one-based index in "7 of 33 files", not the completed count; nil when file counts are unknown.
        public var currentFileIndex: Int? {
            guard let completedFileCount, let totalFileCount else { return nil }
            return min(saturatingAdd(completedFileCount, 1), totalFileCount)
        }

        public var knownRemainingFileCount: Int {
            transfers.reduce(0) { saturatingAdd($0, $1.remainingFileCount ?? 0) }
        }

        public var containsUncounted: Bool { transfers.contains { $0.remainingFileCount == nil } }

        private var transfers: [TransferProgress] {
            switch self {
            case .upload(let progress), .download(let progress):
                [progress]
            case .bidirectional(let upload, let download):
                [upload, download]
            }
        }

        private var countedTransfers: [TransferProgress.Counted]? {
            guard !containsUncounted else { return nil }
            return transfers.compactMap { if case .counted(let value) = $0 { value } else { nil } }
        }
    }
}

public extension GlobalProgress {
    var logDescription: String {
        switch self {
        case .idle:
            "idle"
        case .active(.upload(let upload)):
            "upload \(upload.logDescription)"
        case .active(.download(let download)):
            "download \(download.logDescription)"
        case .active(.bidirectional(let upload, let download)):
            "upload \(upload.logDescription) + download \(download.logDescription)"
        }
    }
}

public extension GlobalProgress.ActiveTransfer.TransferProgress {
    var logDescription: String {
        switch self {
        case .counted(let progress):
            "files \(progress.completedFileCount)/\(progress.totalFileCount)"
                + " bytes \(progress.completedByteCount)/\(progress.totalByteCount)"
        case .uncounted(let progress):
            "files unknown bytes \(progress.completedByteCount)/\(progress.totalByteCount)"
        }
    }
}

private func saturatingAdd<T: FixedWidthInteger>(_ lhs: T, _ rhs: T) -> T {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : value
}

private func fraction<T: BinaryInteger>(completed: T, total: T) -> Double {
    fraction(completed: Double(completed), total: Double(total))
}

private func fraction(completed: Double, total: Double) -> Double {
    guard total > 0 else { return 0 }
    return min(completed / total, 1.0.nextDown)
}
