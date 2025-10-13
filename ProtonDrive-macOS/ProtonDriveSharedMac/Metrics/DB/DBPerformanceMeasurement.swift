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

import CoreData
import PDCore

@objc(DBPerformanceMeasurement)
final class DBPerformanceMeasurement: NSManagedObject, DomainConvertible {
    typealias DomainObject = PerformanceMeasurementEvent

    @NSManaged var operationId: String
    @NSManaged var timestamp: Double
    @NSManaged var pipeline: String
    @NSManaged var operationType: String
    @NSManaged var progressInBytes: Int64
    @NSManaged var isReported: Bool

    func update(from measurement: PerformanceMeasurementEvent) {
        self.operationId = measurement.operationId
        self.timestamp = measurement.timestamp
        self.pipeline = measurement.pipeline.rawValue
        self.operationType = measurement.operationType.rawValue
        self.progressInBytes = measurement.progressInBytes
        self.isReported = measurement.isReported
    }

    func toDomain() throws -> PerformanceMeasurementEvent {
        guard let pipeline = DriveObservabilityPipeline(rawValue: pipeline) else {
            throw DomainConversionError.invalidData
        }

        guard let operationType = PerformanceOperationType(rawValue: operationType) else {
            throw DomainConversionError.invalidData
        }

        return PerformanceMeasurementEvent(
            operationId: operationId,
            timestamp: timestamp,
            pipeline: pipeline,
            operationType: operationType,
            progressInBytes: progressInBytes,
            isReported: isReported
        )
    }
}
