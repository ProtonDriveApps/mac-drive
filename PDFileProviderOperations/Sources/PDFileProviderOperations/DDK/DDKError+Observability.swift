// Copyright (c) 2025 Proton AG
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

import CoreData
import PDCore
import PDDesktopDevKit

extension Swift.Error {
    public func integrityMetricErrorType() -> DDKError.DataIntegrityErrorType? {
        guard case .dataIntegrity(_, let type, _, _) = self as? DDKError else { return nil }
        return type
    }
}
    
extension DDKError {
    public static func sendIntegrityMetric(
        type: DDKError.DataIntegrityErrorType,
        share: PDCore.Share,
        node: PDCore.Node,
        in moc: NSManagedObjectContext
    ) {
        moc.performAndWait {
            switch type {
            case .unknown:
                break
            case .shareMetadataDecryption:
                DriveIntegrityErrorMonitor.reportError(for: share)
            case .fileContentsDecryption:
                DriveIntegrityErrorMonitor.reportContentError(for: node)
            case .nodeMetadataDecryption:
                DriveIntegrityErrorMonitor.reportMetadataError(for: node)
            case .uploadKeyMismatch:
                DriveIntegrityErrorMonitor.reportUploadBlockVerificationError(for: share, fileSize: Int64(node.size))
            }
        }
    }
    
    // swiftlint:disable:next function_parameter_count
    public static func sendIntegrityMetricFromFileUpload(
        type: DDKError.DataIntegrityErrorType,
        share: PDCore.Share,
        identifier: String,
        creationDate: Date,
        fileSize: Int64,
        in moc: NSManagedObjectContext
    ) {
        moc.performAndWait {
            switch type {
            case .unknown:
                break
            case .shareMetadataDecryption:
                DriveIntegrityErrorMonitor.reportError(for: share)
            case .fileContentsDecryption:
                DriveIntegrityErrorMonitor.reportContentErrorDuringFileUpload(identifier: identifier, creationDate: creationDate)
            case .nodeMetadataDecryption:
                DriveIntegrityErrorMonitor.reportMetadataErrorDuringFileUpload(identifier: identifier, creationDate: creationDate)
            case .uploadKeyMismatch:
                DriveIntegrityErrorMonitor.reportUploadBlockVerificationError(for: share, fileSize: fileSize)
            }
        }
    }
}
