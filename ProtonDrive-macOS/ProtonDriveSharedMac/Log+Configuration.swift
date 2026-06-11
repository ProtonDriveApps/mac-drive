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
import ProtonCoreLog

extension Log {
    static var domains: Set<LogDomain> {
        // If detailed logging is enabled, include all domains
        if RuntimeConfiguration.shared.includeTracesInLogs {
            LogDomain.macOSDomains()
        } else {
            LogDomain.macOSDomains(
                appending: RuntimeConfiguration.shared.includedLogDomains,
                subtracting: RuntimeConfiguration.shared.excludedLogDomains
            )
        }
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
            AndFilteredLogger(
                logger: FileLogger(process: fileLog, oneFilePerRun: oneFilePerRun) { compressLogs },
                domains: domains,
                levels: logLevels,
                // skip log events which have a JSON payload - they will we logged by JSONLogger instead
                exclusionFilter: { $0?.hasJSONPayload == true }
            )
        ]

#if DEBUG
        loggers.append(
            AndFilteredLogger(
                logger: DebugLogger(),
                domains: domains,
                levels: logLevels,
                exclusionFilter: { $0?.hasJSONPayload == true }
            )
        )
#endif

        loggers.append(
            ProductionLogger()
        )

        loggers.append(JSONLogger(process: fileLog, oneFilePerRun: oneFilePerRun) { compressLogs })

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

func configureCoreLoggerUsingEnvironmentFromConstants() {
    let hostString = Constants.userApiConfig.environment.doh.defaultHost
    // PMLog uses URL.host() internally, but this method is broken on macOS 13.0-13.2
    // and crashes instead of providing nil. The deprecated `.host` property works ok always.
    // To prevent crash, let's not set the external logger at all if there's no host.
    // The events won't be delivered without host anyways.
    if URL(string: hostString)?.host != nil {
        PMLog.setExternalLoggerHost(hostString)
    }
}
