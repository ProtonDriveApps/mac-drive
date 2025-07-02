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

extension Log {
    static var domains: Set<LogDomain> {
        LogDomain.macOSDomains(
            appending: RuntimeConfiguration.shared.includedLogDomains,
            subtracting: RuntimeConfiguration.shared.excludedLogDomains
        )
    }

    static var logLevels: Set<LogLevel> {
        var logLevels = Set<LogLevel>([.info, .error, .warning])

        if RuntimeConfiguration.shared.includeTracesInLogs {
            logLevels.insert(.trace)
            logLevels.insert(.debug)
        }

#if DEBUG
        logLevels.insert(.debug)
#endif

        return logLevels
    }

    /// Configures all loggers for the macOS app and macOS FileProvider.
    public static func configure(system: LogSystem, compressLogs: Bool) {
        Log.trace("Config logger \(system): \(Date.timeIntervalSinceReferenceDate)")

        // Set up logging options

        self.logSystem = system

        Log.enableTraces = RuntimeConfiguration.shared.includeTracesInLogs
        let oneFilePerRun = RuntimeConfiguration.shared.includeTracesInLogs

        let fileLog: FileLog = system == LogSystem.macOSApp ? .macOSApp : .macOSFileProvider

        // Create loggers

        var loggers: [LoggerProtocol] = [
            AndFilteredLogger(logger: FileLogger(process: fileLog, oneFilePerRun: oneFilePerRun) { compressLogs },
                              domains: domains,
                              levels: logLevels)
        ]

#if DEBUG
        loggers.append(
            AndFilteredLogger(logger: DebugLogger(),
                              domains: domains,
                              levels: logLevels)
        )
#endif

        loggers.append(
            ProductionLogger()
        )

        if RuntimeConfiguration.shared.sqliteLogging {
            loggers.append(SQLiteLogger(system: system))
        }

        let oldLogger = self.logger
        let newLogger = CompoundLogger(loggers: loggers)
        (oldLogger as? DelayedLogger)?.drain(into: newLogger)
        self.logger = newLogger

        if RuntimeConfiguration.shared.enableTestAutomation, system == .macOSFileProvider {
            // this must happen after setting the CompoundLogger.
            configureFileProviderForTesting(loggers)
        }

        Log.info("Process identifier = \(ProcessInfo.processInfo.processIdentifier)", domain: .application)
        Log.info("Client version = \(Constants.clientVersion)", domain: .application)
    }
}
