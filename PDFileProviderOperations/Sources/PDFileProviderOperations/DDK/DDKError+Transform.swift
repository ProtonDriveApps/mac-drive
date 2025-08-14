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
import PDDesktopDevKit
import PDClient
import FileProvider
import PDFileProvider
import ProtonDriveProtos

extension Swift.Error {
    func toFileProviderCompatibleError() -> Swift.Error {
        if let ddkError = self as? DDKError {
            return ddkError.toFileProviderCompatibleError()
        } else if let metadataError = self as? DDKMetadataUpdater.MetadataUpdateError {
            return metadataError.toFileProviderCompatibleError()
        } else if let errors = self as? Errors {
            return PDFileProvider.Errors.mapToFileProviderError(errors) ?? NSFileProviderError.create(.cannotSynchronize, from: self)
        } else if let fileProviderError = self as? NSFileProviderError {
            return fileProviderError
        // we limit the check to .userCancelled because it's the only CocoaError that we currently know the file provider is happy to receive
        } else if let cocoaError = self as? CocoaError, cocoaError.code == .userCancelled {
            return cocoaError
        } else {
            // this is a catch-all for everything that's thrown
            return NSFileProviderError.create(.serverUnreachable, from: self)
        }
    }
}

extension DDKError {
    func toFileProviderCompatibleError() -> Swift.Error {
        switch self {
        case .invalidRefreshToken:
            return NSFileProviderError.create(.serverUnreachable, from: self)
        case .functionCallFailed:
            return NSFileProviderError.create(.serverUnreachable, from: self)
        case .userActionable(_, let inner, _),
             .nonActionable(_, let inner, _),
             .developerError(let inner, _),
             .cancellation(let inner, _),
             .dataIntegrity(_, _, let inner, _):
            return inner.toFileProviderCompatibleError()
        }
    }
}

extension DDKMetadataUpdater.MetadataUpdateError {
    func toFileProviderCompatibleError() -> Swift.Error {
        switch self {
        case .noCachedResponse:
            return NSFileProviderError.create(.cannotSynchronize, from: self)
        case .metadataUpdateFailed:
            return NSFileProviderError.create(.cannotSynchronize, from: self)
        case .fieldMissing:
            return NSFileProviderError.create(.cannotSynchronize, from: self)
        }
    }
}

extension ProtonDriveProtos.Error {
    func toFileProviderCompatibleError() -> Swift.Error {
        switch domain {
        case .successfulCancellation:
            return CocoaError(.userCancelled)
        case .api where primaryCode == APIErrorCodes.itemOrItsParentDeletedErrorCode.rawValue:
            return NSFileProviderError.create(.serverUnreachable, from: self)
        case .api where primaryCode == APIErrorCodes.protonDocumentCannotBeCreatedFromMacOSAppErrorCode.rawValue:
            return NSFileProviderError.create(.excludedFromSync, from: self)
        case .api:
            return NSFileProviderError.create(.serverUnreachable, from: self)
        case .network, .transport:
            return NSFileProviderError.create(.serverUnreachable, from: self)
        case .serialization:
            return NSFileProviderError.create(.cannotSynchronize, from: self)
        case .cryptography, .dataIntegrity:
            return NSFileProviderError.create(.cannotSynchronize, from: self)
        case .undefined, .UNRECOGNIZED:
            return NSFileProviderError.create(.cannotSynchronize, from: self)
        }
    }
}

extension NSFileProviderError {
    static func create(_ status: NSFileProviderError.Code, from error: ProtonDriveProtos.Error) -> Self {
        return NSFileProviderError(
            status,
            userInfo: [
                NSDebugDescriptionErrorKey: "FP error code: \(status). Original error: \(error.message), \(error.primaryCode)",
                NSUnderlyingErrorKey: NSError(domain: error.type, code: Int(error.primaryCode), userInfo: [
                    NSLocalizedDescriptionKey: error.message, NSDebugDescriptionErrorKey: "\(error.domain)\n\(error.context)"
                ])
            ]
        )
    }
}
