// Copyright (c) 2023 Proton AG
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

import SwiftUI

enum FileProviderStatus {
    case notRunning
    case runningCorrectly
    case tooManyFileProviders(Int)
    case tooManyApps(Int)
    case wrongFileProvider(String)

    init(processes: [String]) {
        let fileProviderProcesses = processes.filter { String(describing: $0).contains("/Contents/MacOS/ProtonDriveFileProviderMac") }
        let appProcesses = processes.filter { String(describing: $0).contains("/Contents/MacOS/Proton Drive") }

        if fileProviderProcesses.count > 1 {
            self = .tooManyFileProviders(fileProviderProcesses.count)
        } else if appProcesses.count > 1 {
            self = .tooManyApps(appProcesses.count)
        } else if let fileProviderPath = fileProviderProcesses.first,
                    let appPath = appProcesses.first,
                    !fileProviderPath.sharesPrefix(before: "Proton Drive.app/Contents/", with: appPath) {
            self = .wrongFileProvider(fileProviderProcesses.first ?? "n/a")
        } else if fileProviderProcesses.isEmpty {
            self = .notRunning
        } else {
            self = .runningCorrectly
        }
    }

    var iconColor: String {
        switch self {
        case .tooManyFileProviders(_), .tooManyApps(_), .wrongFileProvider(_):
            "🔴"
        case .notRunning:
            "🟠"
        case .runningCorrectly:
            "🟢"
        }
    }

    var description: String {
        switch self {
        case .tooManyFileProviders(let count):
            "Too many fileproviders: \(count)"
        case .tooManyApps(let count):
            "Too many apps: \(count)"
        case .wrongFileProvider(let path):
            "Wrong file provider: \(path)"
        case .notRunning:
            "File provider not running"
        case .runningCorrectly:
            "Running correctly"
        }
    }
}

extension String {
    /// Return true if `self` and `other` share the same content up to `separator`
    func sharesPrefix(before separator: String, with other: String) -> Bool {
        let prefix1 = self.suffix(after: "/").split(separator: separator).first
        let prefix2 = other.suffix(after: "/").split(separator: separator).first
        return prefix1 == prefix2
    }

    func suffix(after: String) -> String {
        guard let index = self.firstIndex(of: "/") else {
            return self
        }
        return String(self.suffix(from: index))
    }
}
