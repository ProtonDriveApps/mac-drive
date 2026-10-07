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
        case .serialization, .cryptography, .dataIntegrity, .unknownIo, .fileSystem, .undefined:
            return innerError?.asFileProviderCompatibleError() ??
                NSFileProviderError.create(.cannotSynchronize, from: self)
        }
    }
}

extension Swift.Error {

    var folderLimitReason: FolderLimitReason? {
        if let limitError = self as? FolderRateLimitedError {
            return limitError.reason
        }
        let codes = candidateErrorCodes()
        if codes.contains(ResponseCode.tooManyChildren.rawValue) { return .tooManyChildren }
        if codes.contains(ResponseCode.nestingTooDeep.rawValue) { return .nestingTooDeep }
        return nil
    }
}

extension Swift.Error {

    var quotaLimitReason: QuotaLimitReason? {
        if let quotaError = self as? QuotaExceededError {
            return quotaError.reason
        }
        let codes = candidateErrorCodes()
        if codes.contains(ResponseCode.insufficientQuota.rawValue) { return .insufficientQuota }
        if codes.contains(ResponseCode.insufficientSpace.rawValue) { return .insufficientSpace }
        return nil
    }
}

private extension Swift.Error {

    /// Walks the error tree and collects candidate backend/error codes, so quota
    /// (200001/200002) and folder (200300/200301) limits are detected regardless
    /// of how the error is wrapped or nested. Bounded by `depth` to guard against cycles.
    func candidateErrorCodes(depth: Int = 6) -> Set<Int> {
        guard depth > 0 else { return [] }
        var codes: Set<Int> = []

        if let quotaError = self as? QuotaExceededError {
            codes.insert(quotaError.reason.responseCode)
            return codes
        }

        if let folderError = self as? FolderRateLimitedError {
            codes.insert(folderError.reason.responseCode)
            return codes
        }

        if let sdkError = self as? ProtonDriveSDKError {
            if let primaryCode = sdkError.primaryCode { codes.insert(primaryCode) }
            if let secondaryCode = sdkError.secondaryCode { codes.insert(secondaryCode) }
            if let inner = sdkError.innerError {
                codes.formUnion(inner.candidateErrorCodes(depth: depth - 1))
            }
            return codes
        }

        if let responseError = self as? ResponseError {
            if let responseCode = responseError.responseCode { codes.insert(responseCode) }
            if let httpCode = responseError.httpCode { codes.insert(httpCode) }
            if let underlying = responseError.underlyingError {
                codes.formUnion(underlying.candidateErrorCodes(depth: depth - 1))
            }
            return codes
        }

        // A bare `NSError.code` from an arbitrary domain isn't trusted: an unrelated code could equal a
        // quota/folder response code (200001/200002/200300/200301) and wrongly arm the limiter.
        let nsError = self as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            codes.formUnion(underlying.candidateErrorCodes(depth: depth - 1))
        }
        for underlying in nsError.underlyingErrors {
            codes.formUnion(underlying.candidateErrorCodes(depth: depth - 1))
        }
        return codes
    }
}

private extension QuotaLimitReason {
    var responseCode: Int {
        switch self {
        case .insufficientQuota: return ResponseCode.insufficientQuota.rawValue
        case .insufficientSpace: return ResponseCode.insufficientSpace.rawValue
        }
    }
}

private extension FolderLimitReason {
    var responseCode: Int {
        switch self {
        case .tooManyChildren: return ResponseCode.tooManyChildren.rawValue
        case .nestingTooDeep: return ResponseCode.nestingTooDeep.rawValue
        }
    }
}
