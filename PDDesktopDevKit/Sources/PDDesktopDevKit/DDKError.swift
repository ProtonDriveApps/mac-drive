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
import ProtonDriveProtos

extension ProtonDriveProtos.Error: @retroactive LocalizedError {
    public var errorDescription: String? {
        let description = "\(message)\nType: \(type)\nContext: \(context)"

        if hasInnerError {
            return "\(description)\nInner error: \(innerError.errorDescription ?? "")"
        } else {
            return description
        }
    }
}

public enum DDKError: LocalizedError, Equatable {
    public enum DataIntegrityErrorType: Equatable {
        case unknown
        case shareMetadataDecryption
        case nodeMetadataDecryption(NodeMetadataPart) // NodeMetadataDecryptionException
        case fileContentsDecryption // FileContentsDecryptionException
        case uploadKeyMismatch // NodeKeyAndSessionKeyMismatchException, SessionKeyAndDataPacketMismatchException
        
        public enum NodeMetadataPart: Int64 {
            case unknown = -1
            case key = 0
            case passphrase = 1
            case name = 2
            case extendedAttributes = 3
            case contentKey = 4
            case hashKey = 5
            case blockSignature = 6
            case thumbnail = 7
        }

        init(primaryCode: Int64, secondaryCode: Int64) {
            switch primaryCode {
            case 0: self = .unknown
            case 1: self = .shareMetadataDecryption
            case 2: self = .nodeMetadataDecryption(NodeMetadataPart(rawValue: secondaryCode) ?? .unknown)
            case 3: self = .fileContentsDecryption
            case 4: self = .uploadKeyMismatch
            default: self = .unknown
            }
        }

        var rawValue: Int64 {
            switch self {
            case .unknown: return 0
            case .shareMetadataDecryption: return 1
            case .nodeMetadataDecryption: return 2
            case .fileContentsDecryption: return 3
            case .uploadKeyMismatch: return 4
            }
        }
    }
    
    case invalidRefreshToken(failedFunctionName: String)
    case functionCallFailed(failedFunctionName: String)
    case dataIntegrity(message: String, type: DataIntegrityErrorType, inner: ProtonDriveProtos.Error, failedFunctionName: String)
    case userActionable(message: String, inner: ProtonDriveProtos.Error, failedFunctionName: String)
    case nonActionable(message: String, inner: ProtonDriveProtos.Error, failedFunctionName: String)
    case developerError(inner: ProtonDriveProtos.Error, failedFunctionName: String)
    case cancellation(inner: ProtonDriveProtos.Error, failedFunctionName: String)

    private static let invalidRefreshTokenCode: Int = 10013

    init(failedFunctionName: String) {
        self = .functionCallFailed(failedFunctionName: failedFunctionName)
    }

    init(errorResponse: ProtonDriveProtos.Error, failedFunctionName: String) {
        switch errorResponse.domain {
        case .undefined:
            self = .nonActionable(message: "\(errorResponse.message) [\(errorResponse.type)]",
                                  inner: errorResponse,
                                  failedFunctionName: failedFunctionName)
        case .successfulCancellation:
            self = .cancellation(
                inner: errorResponse,
                failedFunctionName: failedFunctionName)
        case .api where errorResponse.primaryCode == Self.invalidRefreshTokenCode:
            self = .invalidRefreshToken(failedFunctionName: failedFunctionName)
        case .network, .transport, .api:
            self = .userActionable(message: errorResponse.message,
                                   inner: errorResponse,
                                   failedFunctionName: failedFunctionName)
        case .serialization, .cryptography, .UNRECOGNIZED:
            self = .nonActionable(message: errorResponse.message,
                                  inner: errorResponse,
                                  failedFunctionName: failedFunctionName)
        case .dataIntegrity:
            self = .dataIntegrity(message: "Integrity error: " + errorResponse.message,
                                  type: DataIntegrityErrorType(primaryCode: errorResponse.primaryCode,
                                                               secondaryCode: errorResponse.secondaryCode),
                                  inner: errorResponse,
                                  failedFunctionName: failedFunctionName)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidRefreshToken:
            return "Invalid refresh token"
        case .functionCallFailed(let functionName):
            return "Error calling \(functionName)"
        case .userActionable(_, let inner, _), .nonActionable(_, let inner, _), .dataIntegrity(_, _, let inner, _):
            return inner.localizedDescription
        case .developerError(let inner, _), .cancellation(let inner, _):
            return inner.localizedDescription
        }
    }
}
