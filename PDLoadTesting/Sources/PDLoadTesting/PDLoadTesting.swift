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
import os.log

public enum LoadTesting {
    public static private(set) var isEnabled = false
    
    public static func enableLoadTesting() {
        Logger(subsystem: "ch.protonmail.drive", category: "loadTesting")
            .warning("Load testing enabled")
        isEnabled = true
    }
}

public class TestDelegate: NSObject, URLSessionDelegate {
    public func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        let credential = URLCredential(trust: trust)
        return (.useCredential, credential)
    }
}
