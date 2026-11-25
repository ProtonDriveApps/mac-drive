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

#if DEBUG
import Foundation

/// A network request that failed while a UI test was running: an HTTP status outside 200–299
/// (`status`, `code`, `error`) or a transport error (`domain`, `errorCode`, `error`).
struct FailedRequestRecord: Equatable {
    enum Process: String {
        case app
        case `extension`
        case test
    }

    let process: Process
    /// The running UI test as `Class/method`.
    let testCase: String
    let method: String
    let host: String
    /// The URL path without query string.
    let path: String
    let status: Int?
    /// The API `Code` from the response body.
    let code: Int?
    /// The API `Error` from the response body, or the description of a transport error.
    let error: String?
    let domain: String?
    let errorCode: Int?
}

protocol FailedRequestContextResource {
    var process: FailedRequestRecord.Process { get }
    /// The running UI test, or nil when no UI test is running.
    var testCase: String? { get }
}

protocol FailedRequestLogResource {
    func write(_ record: FailedRequestRecord)
}
#endif
