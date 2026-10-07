// Copyright (c) 2026 Proton AG
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
import ProtonCoreObservability

public actor DriveSDKUploadPerformanceObservabilityMonitor {
    private let environment: ObservabilityEnvProtocol.Type

    public init(environment: ObservabilityEnvProtocol.Type = ObservabilityEnv.self) {
        self.environment = environment
    }

    public func reportSmallFileUploadThroughput(
        _ throughput: Int,
        route: DriveObservabilityUploadRoute
    ) {
        report(
            name: .smallFileThroughputHistogram,
            value: throughput,
            labels: [DriveSDKObservabilityLabelKey.uploadRoute.rawValue: route.rawValue]
        )
    }

    public func reportLargeFileUploadThroughput(
        _ throughput: Int,
        blockCount: DriveObservabilityBlockCount
    ) {
        report(
            name: .largeFileThroughputHistogram,
            value: throughput,
            labels: [DriveSDKObservabilityLabelKey.blockCount.rawValue: blockCount.rawValue]
        )
    }

    public func reportLargeRouteActiveTimeShare(
        percentage: Int,
        sizeClass: DriveObservabilitySizeClass
    ) {
        report(
            name: .largeFileActiveTimeShareHistogram,
            value: percentage,
            labels: [DriveSDKObservabilityLabelKey.sizeClass.rawValue: sizeClass.rawValue]
        )
    }

    public func reportSmallRouteActiveTimeShare(percentage: Int) {
        report(
            name: .smallFileActiveTimeShareHistogram,
            value: percentage,
            labels: [:]
        )
    }

    private func report(
        name: DriveSDKUploadPerformanceObservabilityName,
        value: Int,
        labels: [String: String]
    ) {
        let event = ObservabilityEvent(
            name: name.rawValue,
            value: value,
            labels: HistogramObservationLabels(labels: labels),
            version: .v1
        )
        
        environment.report(event)
    }
}

enum DriveSDKUploadPerformanceObservabilityName: String {
    case smallFileThroughputHistogram = "drive_sdk_upload_small_file_throughput_histogram"
    case largeFileThroughputHistogram = "drive_sdk_upload_large_file_throughput_histogram"
    
    case smallFileActiveTimeShareHistogram = "drive_sdk_upload_small_file_active_time_share_histogram"
    case largeFileActiveTimeShareHistogram = "drive_sdk_upload_large_file_active_time_share_histogram"
}
