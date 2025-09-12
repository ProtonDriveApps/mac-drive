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

typealias EventLoopPriorityData = EventLoopsExecutionData.LoopData

enum EventLoopExecutionPriority: Comparable {
    case high
    case low(priority: Int) // The bigger number the higher priority

    private var sortValue: Int {
        switch self {
        case .high:
            Int.max
        case .low(let priority):
            priority
        }
    }

    static func < (lhs: EventLoopExecutionPriority, rhs: EventLoopExecutionPriority) -> Bool {
        return lhs.sortValue < rhs.sortValue
    }
}

protocol EventLoopPriorityPolicyProtocol {
    func getPriority(with data: EventLoopPriorityData) -> EventLoopExecutionPriority?
}

final class EventLoopPriorityPolicy: EventLoopPriorityPolicyProtocol {
    private var isDebug: Bool {
        #if DEBUG
        return Constants.isUnitTest ? false : true
        #else
        return false
        #endif
    }

    func getPriority(with data: EventLoopPriorityData) -> EventLoopExecutionPriority? {
        switch data.type {
        case .own:
            return getOwnVolumePriority(with: data)
        case .activeShared:
            return getSharedVolumePriority(with: data, isActive: true)
        case .inactiveShared:
            return getSharedVolumePriority(with: data, isActive: false)
        }
    }

    private func getOwnVolumePriority(with data: EventLoopPriorityData) -> EventLoopExecutionPriority? {
        let threshold = thresholdForOwnedVolume(isBackground: data.isRunningInBackground)
        if data.isRunningInBackground {
            // background
            return getPriority(data: data, thresholdDelayInSeconds: threshold, isHighPriority: true)
        } else {
            // foreground
            return getPriority(data: data, thresholdDelayInSeconds: threshold, isHighPriority: true)
        }
    }

    private func thresholdForOwnedVolume(isBackground: Bool) -> Double {
        if isDebug {
            return isBackground ? 10.0.minutes : 10.0.seconds
        } else {
            return isBackground ? 30.0.minutes : 30.0.seconds
        }
    }

    func getSharedVolumePriority(with data: EventLoopPriorityData, isActive: Bool) -> EventLoopExecutionPriority? {
        let threshold = thresholdForSharedVolume(isBackground: data.isRunningInBackground, isActive: isActive)
        if data.isRunningInBackground {
            // background
            return getPriority(data: data, thresholdDelayInSeconds: threshold, isHighPriority: false)
        } else if isActive {
            // foreground & active
            return getPriority(data: data, thresholdDelayInSeconds: threshold, isHighPriority: true)
        } else {
            // foreground
            return getPriority(data: data, thresholdDelayInSeconds: threshold, isHighPriority: false)
        }
    }

    private func thresholdForSharedVolume(isBackground: Bool, isActive: Bool) -> Double {
        if isDebug {
            if isBackground {
                return 8.0.hours
            } else if isActive {
                return 10.0.seconds
            } else {
                return 200.0.seconds
            }
        } else {
            if isBackground {
                return 24.0.hours
            } else if isActive {
                return 30.0.seconds
            } else {
                return 10.0.minutes
            }
        }
    }

    private func getPriority(
        data: EventLoopPriorityData,
        thresholdDelayInSeconds: Double,
        isHighPriority: Bool
    ) -> EventLoopExecutionPriority? {
        let interval = data.currentDate.timeIntervalSince(data.lastDate)
        // Comparing two Doubles here, let's round to be sure
        let secondsSinceThreshold = Int(round(interval - thresholdDelayInSeconds))
        guard secondsSinceThreshold >= 0 else {
            // current date doesn't satisfy the threshold delay
            return nil
        }

        if isHighPriority {
            // This is priority volume and should be polled right away
            return .high
        } else {
            // Lower priority volume, but current date already satisfies the treshold delay
            return .low(priority: secondsSinceThreshold)
        }
    }
}
