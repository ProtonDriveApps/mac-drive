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
import ProtonCoreNetworking

public extension NetworkStateError {
    /// Recognises failures where the request never reached the server, as opposed to the server
    /// rejecting it.
    static func getOfflineError(from error: Error) -> NetworkStateError? {
        if let error = error as? NetworkStateError {
            return error
        }
        // Includes the TLS and censorship codes ProtonCore folds into ResponseError.
        if error.isNetworkIssueError {
            return .deviceIsOffline
        }
        // AuthErrors bridges to NSError under its own domain, hiding the underlying URL error.
        if let authError = error as? AuthErrors {
            return isOfflineURLError(authError.underlyingError) ? .deviceIsOffline : nil
        }
        // URLError bridges to NSError, so this covers both.
        let nsError = error as NSError
        if isOfflineURLError(nsError) {
            return .deviceIsOffline
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return getOfflineError(from: underlying)
        }
        return nil
    }

    private static func isOfflineURLError(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && offlineURLErrorCodes.contains(error.code)
    }

    /// Deliberately excludes codes for bad requests or broken server responses, so those stay visible.
    private static let offlineURLErrorCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorTimedOut,
        NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive,
        NSURLErrorSecureConnectionFailed
    ]
}
