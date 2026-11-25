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
import PDLocalization

/// Error with user friendly failure reason
public enum PhotosFailureUserError: Error {
    case accessFileFailed
    case connectionError
    case corruptedAsset
    case deviceStorageFull
    case driveStorageFull
    case encryptionFailed
    case iCloudNotReachable
    case invalidTimestamp
    case loadResourceFailed
    case missingPermission
    case nameValidationError
    case unknown
    case partiallyInAlbum
}

extension PhotosFailureUserError {
    public var isRetriable: Bool {
        switch self {
        case .partiallyInAlbum:
            return false
        case .accessFileFailed, .connectionError, .corruptedAsset, .deviceStorageFull, .driveStorageFull,
             .encryptionFailed, .iCloudNotReachable, .invalidTimestamp, .loadResourceFailed,
             .missingPermission, .nameValidationError, .unknown:
            return true
        }
    }
}
