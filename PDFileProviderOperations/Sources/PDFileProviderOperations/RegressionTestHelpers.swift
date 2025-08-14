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
import PDCore

/// Enables changing the behavior of the app for regression testing purposes (e.g. triggering errors or other hard-to-duplicate conditions.
class RegressionTestHelpers {
    private var alreadyUsed = Set<String>()

    /// Triggers an error for certain file names.
    func error(for item: NSFileProviderItem, operation: FileProviderOperation) -> Error? {
        if alreadyUsed.contains(item.filename) {
            return nil
        }

        let fileNameToErrorMap: [String: Error] = [
            "proton_drive_test_error_notAuthenticated.err": NSFileProviderError(.notAuthenticated),
            "proton_drive_test_error_insufficientQuota.err": NSFileProviderError(.insufficientQuota),
            "proton_drive_test_error_serverUnreachable.err": NSFileProviderError(.serverUnreachable),
            "proton_drive_test_error_cannotSynchronize.err": NSFileProviderError(.cannotSynchronize),
        ]

        if let error = fileNameToErrorMap[item.filename] {
            alreadyUsed.insert(item.filename)
            return error
        }

        return nil
    }
}
