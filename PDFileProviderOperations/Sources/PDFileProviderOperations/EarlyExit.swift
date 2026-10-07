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
import FileProvider

public enum EarlyExit {
    
    public enum Reason: Equatable {
        case noChildSession
        case fullResyncInProgress
        case recoveryInProgress
        case domainShouldBeDisconnectedDuringCacheRebuild
    }
    
    public static func error(reason: EarlyExit.Reason) -> Error {
        switch reason {
        case .noChildSession:
            return CocoaError(
                .userCancelled,
                userInfo: [
                    NSDebugDescriptionErrorKey: "CocoaError.cancelled. No child session in the extension",
                    NSLocalizedDescriptionKey: "Operation cancelled due to user session refreshing"
                ]
            )
        case .fullResyncInProgress:
            return NSFileProviderError.create(
                .cannotSynchronize,
                userFacingDescription: "Operation delayed until full resync completes"
            )
        case .recoveryInProgress:
            return CocoaError(
                .userCancelled,
                userInfo: [
                    NSDebugDescriptionErrorKey: "CocoaError.cancelled. Recovery in progress",
                    NSLocalizedDescriptionKey: "Operation cancelled due to recovery in-progress"
                ]
            )
        case .domainShouldBeDisconnectedDuringCacheRebuild:
            return NSFileProviderError.create(
                .cannotSynchronize,
                userFacingDescription: "Operation delayed until latest metadata fetched"
            )
        }
    }
}
