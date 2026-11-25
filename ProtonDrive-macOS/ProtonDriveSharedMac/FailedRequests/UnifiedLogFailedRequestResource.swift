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
import os

/// Writes each record as one JSON line to the unified log, where the UI test runner
/// (`build_defs/failed_requests.py`) reads it with `log show`.
struct UnifiedLogFailedRequestResource: FailedRequestLogResource {
    static let subsystem = "ch.protonmail.drive.uitests"
    static let category = "failed-requests"
    static let version = 1

    private let logger = Logger(subsystem: Self.subsystem, category: Self.category)

    func write(_ record: FailedRequestRecord) {
        guard let message = Self.message(for: record) else { return }
        // Default level: the system stores these lines, info lines only in memory.
        logger.log("\(message, privacy: .public)")
    }

    static func message(for record: FailedRequestRecord) -> String? {
        let fields: [String: Any?] = [
            "v": version,
            "process": record.process.rawValue,
            "case": record.testCase,
            "method": record.method,
            "host": record.host,
            "path": record.path,
            "status": record.status,
            "code": record.code,
            "error": record.error,
            "domain": record.domain,
            "error_code": record.errorCode,
        ]
        let object = fields.compactMapValues { $0 }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
#endif
