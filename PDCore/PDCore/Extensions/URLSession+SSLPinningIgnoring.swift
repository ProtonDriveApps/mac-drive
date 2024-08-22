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

#if LOAD_TESTING && SSL_PINNING
#error("Load testing requires turning off SSL pinning, so it cannot be set for SSL-pinning targets")
#endif

extension URLSession {
    
    static func forUploading(delegate: URLSessionDelegate? = nil) -> URLSession {
        if let delegate {
            return URLSession(configuration: .forUploading, delegate: delegate, delegateQueue: nil)
        } else {
            #if LOAD_TESTING && !SSL_PINNING
            // according to URLSession docs, the delegate is retained
            let testDelegate = TestDelegate()
            return URLSession(configuration: .forUploading, delegate: delegate ?? testDelegate, delegateQueue: nil)
            #else
            return URLSession(configuration: .forUploading)
            #endif
        }
    }
    
    static func forDownloading() -> URLSession {
        #if LOAD_TESTING && !SSL_PINNING
        // according to URLSession docs, the delegate is retained
        let testDelegate = TestDelegate()
        return URLSession(configuration: .forUploading, delegate: testDelegate, delegateQueue: nil)
        #else
        return URLSession(configuration: .forUploading)
        #endif
    }
}

#if LOAD_TESTING && !SSL_PINNING
class TestDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let credential = URLCredential(trust: trust)
        return (.useCredential, credential)
    }
}
#endif
