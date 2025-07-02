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
import ProtonCoreUtilities

// MARK: - Progress management and cancellation

public final class FileOperationProgresses {
    private var progresses: Atomic<[Progress]> = .init([])

    public init() {}

    public func add(_ progress: Progress?) {
        Log.trace("FileOperationProgresses")
        progresses.mutate { if let progress { $0.append(progress) } }
    }

    public func remove(_ progress: Progress?) {
        Log.trace("FileOperationProgresses")
        progresses.mutate { if let progress { $0 = $0.removing(progress) } }
    }

    public func invalidateProgresses() {
        progresses.mutate {
            $0.forEach {
                $0.cancel(reason: .fileProviderDeinited)
            }
            $0.removeAll()
        }
    }

    deinit {
        invalidateProgresses()
    }
}

// MARK: Cancellation reason

public extension Progress {
    func cancel(reason: CancellationReason) {
        self.setUserInfoObject(
            reason,
            forKey: ProgressUserInfoKey.cancellationReason
        )
        self.cancel()
    }

    var cancellationReason: CancellationReason {
        userInfo[ProgressUserInfoKey.cancellationReason] as? CancellationReason ?? .unknown
    }
}

extension ProgressUserInfoKey {
    public static let cancellationReason = ProgressUserInfoKey(rawValue: "CancellationReason")
}

public enum CancellationReason: Error {
    case unknown
    case fileProviderDeinited
}
