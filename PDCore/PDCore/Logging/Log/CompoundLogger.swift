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

public final class CompoundLogger: LoggerProtocol {
    private let loggers: [LoggerProtocol]

    public init(loggers: [LoggerProtocol]) {
        self.loggers = loggers
    }

    public func log(_ level: LogLevel, message: String, system: LogSystem, domain: LogDomain, sendToSentryIfPossible: Bool) {
        loggers.forEach {
            $0.log(level, message: message, system: system, domain: domain, sendToSentryIfPossible: sendToSentryIfPossible)
        }
    }

    public func log(_ error: NSError, system: LogSystem, domain: LogDomain, sendToSentryIfPossible: Bool) {
        loggers.forEach {
            $0.log(error, system: system, domain: domain, sendToSentryIfPossible: sendToSentryIfPossible)
        }
    }
}
