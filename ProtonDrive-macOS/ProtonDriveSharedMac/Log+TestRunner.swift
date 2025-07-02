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

import Foundation
import PDCore

private class TestFileLogger: LoggerProtocol {
    private let fileLogger: FileLogger

    fileprivate init(process: FileLog, subdirectory: String) {
        self.fileLogger = FileLogger(process: process, subdirectory: subdirectory, oneFilePerRun: true, compressedLogsDisabled: { false })
    }

    func log(_ level: LogLevel, message: String, system: LogSystem, domain: LogDomain, context: LogContext?, sendToSentryIfPossible: Bool, file: String = #file, function: String = #function, line: Int = #line) {
        fileLogger.log(level, message: message, system: system, domain: domain, context: context, sendToSentryIfPossible: sendToSentryIfPossible, file: file, function: function, line: line)
    }
}

extension Log {
    /// Set up logger for TestRunner in the app (or tear it down, if testRunId is nil).
    /// Only called from the app, never the fileProvider.
    public static func configureAppForTesting(testRunId: String?) {
        Log.trace("\(testRunId ?? "n/a")")

        guard RuntimeConfiguration.shared.enableTestAutomation else {
            return
        }

        if let testRunId {
            do {
            try addTestRunLogger(testRunId, fileLog: .macOSApp)
            } catch {
                Log.error("Couldn't configure logger for tests", error: error, domain: .testRunner)
            }
        } else {
            removeTestRunLogger()
        }
    }

    /// Set up logger for TestRunner in the FileProvider (or tear it down, if testRunId is nil).
    /// Only called from the fileProvider, never the app.
    public static func configureFileProviderForTesting(_ loggers: [LoggerProtocol]) {
        do {
            let testRunId = try storedTestRunId()
            Log.trace("Adding TestRunner logger for \(testRunId)")

            try addTestRunLogger(testRunId, fileLog: .macOSFileProvider)
        } catch {
            Log.error("Couldn't configure logger for tests", error: error, domain: .testRunner)
        }
    }

    private static func addTestRunLogger(_ testRunId: String, fileLog: FileLog) throws {
        let testLogger = AndFilteredLogger(logger: TestFileLogger(process: fileLog, subdirectory: testRunId),
                                           domains: domains.union([.testRunner]),
                                           levels: logLevels)

        guard let logger = self.logger as? CompoundLogger else {
            throw PDFileManagerError.cannotReadFile
        }

        logger.append(logger: testLogger)
    }

    private static func removeTestRunLogger() {
        (self.logger as? CompoundLogger)?.removeAll { $0 is TestFileLogger }
    }

    private static func storedTestRunId() throws -> String {
        let testRunId = try String(contentsOf: testRunIdFileURL, encoding: .utf8)
        return testRunId.replacingOccurrences(of: ":", with: ".")
    }

    /// File containing the current test run's id (in main log directory).
    static var testRunIdFileURL: URL {
        return PDFileManager.logsDirectory.appendingPathComponent("test_run_id.txt")
    }
}
