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

extension PDFileManager {
    private static let logsWorkingDirectoryName = "1.WorkingDirectory"
    private static let logsRotationDirectoryName = "2.RotationDirectory"
    private static let logsArchiveDirectoryName = "3.ArchiveDirectory"

    public static func clearLogsDirectory() {
        try? FileManager.default.removeItem(at: PDFileManager.logsDirectory)
    }

    public static func bootstrapLogDirectory() throws {
        try bootstrapLogDirectory(at: logsDirectory)
    }

    /// Uses an explicit filesystem boundary so tests need not touch app-group logs.
    static func bootstrapLogDirectory(at directory: URL) throws {
        for name in [logsWorkingDirectoryName, logsRotationDirectoryName, logsArchiveDirectoryName] {
            try ensureDirectoryExists(directory.appendingPathComponent(name, isDirectory: true))
        }
    }

    public static var logsDirectory: URL {
        guard let logsDirectory = try? PDFileManager.getLogsDirectory() else {
            fatalError("Failed to get logs directory")
        }
        return logsDirectory
    }

    public static let logsWorkingDirectory: URL = logsDirectory.appendingPathComponent(logsWorkingDirectoryName, isDirectory: true)
    public static let logsRotationDirectory: URL = logsDirectory.appendingPathComponent(logsRotationDirectoryName, isDirectory: true)
    public static let logsArchiveDirectory: URL = logsDirectory.appendingPathComponent(logsArchiveDirectoryName, isDirectory: true)
    public static let logsExportDirectory: URL = logsDirectory.appendingPathComponent("ExportDirectory", isDirectory: true)
    public static let observabilityEventsDirectory: URL = logsDirectory.appendingPathComponent("ObservabilityEvents", isDirectory: true)
}
