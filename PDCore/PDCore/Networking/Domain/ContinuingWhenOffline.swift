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

/// Swallows transport failures only; `BootstrapRequiresConnectionError` still propagates.
public func continuingWhenOffline(
    message: String,
    file: String = #filePath,
    function: String = #function,
    line: Int = #line,
    domain: LogDomain,
    _ block: () async throws -> Void
) async throws {
    do {
        try await block()
    } catch {
        guard let offline = NetworkStateError.getOfflineError(from: error) else {
            throw error
        }
        Log.info("\(message) (\(offline))", domain: domain, file: file, function: function, line: line)
    }
}
