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

import Foundation
import PDCore

protocol PlistSaveable {}

extension PlistSaveable {
    func saveToPlist(url: URL, data: [String: Any]) {
        (data as NSDictionary).write(to: url, atomically: true)
    }

    func loadFromPlist(url: URL) -> [String: Any]? {
        return NSDictionary(contentsOf: url) as? [String: Any]
    }
}

/// Enables changing the app's (and fileprovider's) behavior during runtime by setting properties in a plist stored in the group container directory.
/// Can be used to aid debugging issues in the wild.
struct RuntimeConfiguration: PlistSaveable {
    /// Logs very detailed information control flow information, making it easier to infer the sequence of events from logs.
    /// Generates huge amount of logs, use sparingly!
    private(set) var includeTracesInLogs = false

    /// Show non-file-specific change enumeration entry (i.e. "Detecting remote changes").
    /// Changes to this value take effect immediately after restarting the app.
    private(set) var includeChangeEnumerationSummaryInTrayApp = false

    /// Show per-file information about enumerated changes.
    /// Changes to this value take effect after items have been enumerated.
    private(set) var includeChangeEnumerationDetailsInTrayApp = true

    /// Show non-file-specific item enumeration entry (i.e. "Listing local files and folders").
    /// Changes to this value take effect immediately after restarting the app.
    private(set) var includeItemEnumerationSummaryInTrayApp = false

    /// Show per-file information about enumerated items.
    /// Changes to this value take effect after items have been enumerated.
    private(set) var includeItemEnumerationDetailsInTrayApp = false

    private(set) var eventLoopInterval = 90.0

    /// Writes logs to SQLite DB.
    private(set) var sqliteLogging = false

    /// Listen to events from the the TestRunner?
    private(set) var enableTestAutomation: Bool = false

    /// Disable SSL certificate checking in the .NET SDK
    private(set) var ignoreDdkSslCertificateErrors: Bool = false

    /// LogDomains to include
#if DEBUG
    private(set) var includedLogDomainNames = ["syncing", "enumerating", "offlineAvailable"]
#else
    private(set) var includedLogDomainNames = [String]()
#endif
    var includedLogDomains: Set<LogDomain> {
        Set(includedLogDomainNames.compactMap { LogDomain(name: $0) })
    }

    /// LogDomains to exclude
#if DEBUG
    private(set) var excludedLogDomainNames = ["ddk", "clientNetworking", "featureFlags"]
#else
    private(set) var excludedLogDomainNames = [String]()
#endif
    var excludedLogDomains: Set<LogDomain> {
        Set(excludedLogDomainNames.compactMap { LogDomain(name: $0) })
    }

    public static let shared = RuntimeConfiguration()

    private init() {
        do {
            try loadFromFile(from: "RuntimeConfiguration.plist")
            logAllValues()
        } catch {
            Log.error("Loading RuntimeConfiguration failed", error: error, domain: .logs)
        }
    }

    private func logAllValues() {
        let mirror = Mirror(reflecting: self)
        for (propertyName, value) in mirror.children {
            if let propertyName = propertyName {
                Log.debug("RuntimeConfiguration.\(propertyName): \(value)", domain: .logs)
            }
        }
    }

// swiftlint:disable cyclomatic_complexity
    private mutating func loadFromFile(from filename: String) throws {
        guard let dictionary = self.loadFromPlist(url: try configFileURL()) else {
            return
        }

        for (key, value) in dictionary {
            switch key {
            case "includeTracesInLogs":
                if let value = value as? Bool {
                    self.includeTracesInLogs = value
                }
            case "includeChangeEnumerationSummaryInTrayApp":
                if let value = value as? Bool {
                    self.includeChangeEnumerationSummaryInTrayApp = value
                }
            case "includeChangeEnumerationDetailsInTrayApp":
                if let value = value as? Bool {
                    self.includeChangeEnumerationDetailsInTrayApp = value
                }
            case "includeItemEnumerationSummaryInTrayApp":
                if let value = value as? Bool {
                    self.includeItemEnumerationSummaryInTrayApp = value
                }
            case "includeItemEnumerationDetailsInTrayApp":
                if let value = value as? Bool {
                    self.includeItemEnumerationDetailsInTrayApp = value
                }
            case "eventLoopInterval":
                if let value = value as? Double {
                    self.eventLoopInterval = value
                }
            case "sqliteLogging":
                if let value = value as? Bool {
                    self.sqliteLogging = value
                }
            case "enableTestAutomation":
                if let value = value as? Bool {
                    self.enableTestAutomation = value
                }
            case "includedLogDomainNames":
                if let value = value as? [String] {
                    self.includedLogDomainNames = value
                }
            case "excludedLogDomainNames":
                if let value = value as? [String] {
                    self.excludedLogDomainNames = value
                }
            case "ignoreDdkSslCertificateErrors":
                if let value = value as? Bool {
                    self.ignoreDdkSslCertificateErrors = value
                }
            default:
                Log.debug("Unknown entry in file: \(key)", domain: .logs)
            }
        }
    }
// swiftlint:enable cyclomatic_complexity

    private func configFileURL() throws -> URL {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Constants.appContainerGroup) else {
            throw URLError(.cancelled)
        }
        return containerURL.appendingPathComponent("RuntimeConfiguration.plist")
    }

    func toggleDetailedLogging() throws {
        var dictionary = self.loadFromPlist(url: try configFileURL()) ?? [:]
        dictionary["includeTracesInLogs"] = !self.includeTracesInLogs
        self.saveToPlist(url: try configFileURL(), data: dictionary)
        fatalError(ExceptionMessagesExcludedFromSentryCrashReport.toggledRuntimeConfigFile.rawValue)
    }

    /// Call to create a sample config file when needed.
    private func createConfigFile() throws {
        self.saveToPlist(url: try configFileURL(), data: [:])
    }
}
