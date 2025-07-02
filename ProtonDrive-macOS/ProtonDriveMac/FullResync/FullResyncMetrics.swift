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

import PDCore
import ProtonCoreObservability

// See drive_sync_resync_success_total_v1.schema.json

public enum DriveFullResyncStatus: String, Encodable, Equatable {
    case completed
    case cancelled
    case failed
}

public struct DriveFullResyncEventLabel: Encodable, Equatable {
    let status: DriveFullResyncStatus
    let retry: DriveObservabilityRetry
}

extension ObservabilityEvent where Payload == PayloadWithValueAndLabels<Int, DriveFullResyncEventLabel> {
    public static func fullResyncEvent(status: DriveFullResyncStatus, retry: DriveObservabilityRetry) -> Self {
        .init(name: "drive_sync_resync_success_total", labels: .init(status: status, retry: retry))
    }
}

final class FullResyncMonitor {
    
    private var hasRetryHappened: Bool = false
    
    func retryHappened() {
        hasRetryHappened = true
    }
    
    func reportFullResyncEnd(status: DriveFullResyncStatus) {
        let event = ObservabilityEvent.fullResyncEvent(status: status, retry: hasRetryHappened ? .true : .false)
        ObservabilityEnv.report(event)
    }
}
