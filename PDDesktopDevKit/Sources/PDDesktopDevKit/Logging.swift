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
import ProtonDriveSdk

public enum LogLevel: UInt8 {
    case trace = 0
    case debug = 1
    case information = 2
    case warning = 3
    case error = 4
    case critical = 5
    case none = 6
}

public enum LogCategory {
    case other(String)
    case upload
    case download
    
    static func from(_ categoryName: String) -> LogCategory {
        switch categoryName {
        case "upload": return .upload
        case "download": return .download
        default: return .other(categoryName)
        }
    }
}

public enum LoggerProvider {
    
    public private(set) static var handle: Int = 0
    private static var callback: ProtoCallback.Three<LogLevel, String, LogCategory>?

    @discardableResult
    public static func configureLoggingCallback(callback: @escaping (LogLevel, String, LogCategory) -> Void) -> Status {
        // early exit in case the logger was already configured
        guard Self.callback == nil, handle == 0 else { return .ok }
        let internalCallback = ProtoCallback.Three {
            callback($0, $1, $2)
        }
        let pointer = Unmanaged.passUnretained(internalCallback).toOpaque()

        let loggingCallback: @convention(c) (UnsafeRawPointer?, ByteArray) -> Void = { state, logEventBytes in
            guard let state else {
                assertionFailure("log entry has missing information")
                return
            }

            let logEvent = logEventBytes.to(LogEvent.self)
            let level = LogLevel(rawValue: UInt8(logEvent.level)) ?? .none
            let callback = Unmanaged<ProtoCallback.Three<LogLevel, String, LogCategory>>.fromOpaque(state).takeUnretainedValue()

            callback.callback(level, logEvent.message, LogCategory.from(logEvent.categoryName))
        }
        let result = logger_provider_create(Callback(state: pointer, callback: loggingCallback), &handle).asStatus
        if result == .ok {
            self.callback = internalCallback
        }
        return result
    }
}
