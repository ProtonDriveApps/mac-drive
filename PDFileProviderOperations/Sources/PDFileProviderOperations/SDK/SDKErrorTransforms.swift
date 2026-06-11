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

import FileProvider
import PDFileProvider
import ProtonDriveSDK
import PDSDKCore
import PDCore
import PDClient
import ProtonCoreNetworking

extension Swift.Error {
    func toFileProviderCompatibleError() -> Swift.Error {
        if let sdkError = self as? ProtonDriveSDKError {
            return sdkError.asFileProviderCompatibleError()
        } else if self is QuotaExceededError {
            return NSFileProviderError.create(.insufficientQuota, from: self)
        } else if self is FolderRateLimitedError {
            return NSFileProviderError.create(.serverUnreachable, from: self)
        } else if let metadataError = self as? MetadataUpdateError {
            return metadataError.asFileProviderCompatibleError()
        } else if let fileVerificationError = self as? FileVerificationError {
            switch fileVerificationError {
            case .downloadVerificationFailed:
                // prevents the system from automatic retry
                return NSFileProviderError.create(.cannotSynchronize, from: self)
            case .uploadVerificationFailed:
                // allows the system to retry automatically
                return NSFileProviderError.create(.serverUnreachable, from: self)
            }
        } else if let errors = self as? Errors {
            return PDFileProvider.Errors.mapLegacyErrorToFileProviderError(errors)
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

extension ProtonDriveSDKError {
    func asFileProviderCompatibleError() -> Swift.Error {
        switch domain {
        case .successfulCancellation:
            return CocoaError(.userCancelled)
        case .api where primaryCode == APIErrorCodes.protonDocumentCannotBeCreatedFromMacOSAppErrorCode.rawValue:
            return NSFileProviderError.create(.excludedFromSync, from: self)
        case .api where primaryCode == APIErrorCodes.itemOrItsParentDeletedErrorCode.rawValue:
            return NSFileProviderError.create(.serverUnreachable, from: self)
        case .api where primaryCode == APIErrorCodes.currentRevisionIsNotUpToDateErrorCode.rawValue:
            return NSFileProviderError.create(.serverUnreachable, from: self)
        case .api, .network, .transport:
            return NSFileProviderError.create(.serverUnreachable, from: self)
        case .businessLogic, .interop:
            return NSFileProviderError.create(.serverUnreachable, from: self)
        case .serialization, .cryptography, .dataIntegrity, .undefined:
            guard let innerError else {
                return NSFileProviderError.create(.cannotSynchronize, from: self)
            }
            return innerError.asFileProviderCompatibleError()
        }
    }
}

extension Swift.Error {

    var folderLimitReason: FolderLimitReason? {
        if let limitError = self as? FolderRateLimitedError {
            return limitError.reason
        }
        if let sdkError = self as? ProtonDriveSDKError {
            if sdkError.isTooManyChildrenError { return .tooManyChildren }
            if sdkError.isNestingTooDeepError { return .nestingTooDeep }
            return nil
        }
        if let responseError = self as? ResponseError {
            switch responseError.responseCode {
            case ResponseCode.tooManyChildren.rawValue: return .tooManyChildren
            case ResponseCode.nestingTooDeep.rawValue: return .nestingTooDeep
            default: return nil
            }
        }
        let nsError = self as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return underlying.folderLimitReason
        }
        return nil
    }
}

extension Swift.Error {

    var quotaLimitReason: QuotaLimitReason? {
        if let quotaError = self as? QuotaExceededError {
            return quotaError.reason
        }
        if let sdkError = self as? ProtonDriveSDKError {
            if sdkError.isInsufficientQuotaError { return .insufficientQuota }
            if sdkError.isInsufficientSpaceError { return .insufficientSpace }
            return nil
        }
        if let responseError = self as? ResponseError {
            switch responseError.responseCode {
            case ResponseCode.insufficientQuota.rawValue: return .insufficientQuota
            case ResponseCode.insufficientSpace.rawValue: return .insufficientSpace
            default: return nil
            }
        }
        let nsError = self as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return underlying.quotaLimitReason
        }
        return nil
    }
}
