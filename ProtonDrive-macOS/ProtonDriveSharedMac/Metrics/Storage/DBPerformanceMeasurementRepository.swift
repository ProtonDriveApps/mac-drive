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

import Combine
import CoreData
import Foundation
import PDCore

protocol PeformanceMeasurementRepository {
    var unreportedMeasurementPublisher: AnyPublisher<[PerformanceMeasurementEvent], Never> { get }

    func deleteAllMeasurements()
    func record(measurement: PerformanceMeasurementEvent)

    func getLastMeasurement(for operationId: String) async throws -> PerformanceMeasurementEvent?
    func fetchUnreportedMeasurements(
        for type: PerformanceOperationType
    ) async throws -> [PerformanceMeasurementEvent]
    func markAsReported(_ measurements: [PerformanceMeasurementEvent]) async throws
}

final class DBPerformanceMeasurementRepository: PeformanceMeasurementRepository {
    private enum Config {
        static let maxEntryCount = 2048
    }

    private let storageManager: StorageManagerProtocol
    private let measurementObserver: FetchedResultObserver<DBPerformanceMeasurement>

    var unreportedMeasurementPublisher: AnyPublisher<[PerformanceMeasurementEvent], Never> {
        measurementObserver.itemPublisher
    }

    init(
        storageManager: StorageManagerProtocol,
        measurementObserver: FetchedResultObserver<DBPerformanceMeasurement>
    ) {
        self.storageManager = storageManager
        self.measurementObserver = measurementObserver
    }

    public convenience init() {
        let storageManager = GenericStorageManager(
            bundle: Bundle(for: DBPerformanceMeasurementRepository.self),
            suite: .group(named: Constants.appContainerGroup),
            databaseName: "Metrics"
        )

        self.init(
            storageManager: storageManager,
            measurementObserver: FetchedResultObserver(
                fetchRequest: Self.makeUnreportedFetchRequest(),
                context: storageManager.backgroundContext
            )
        )
    }

    func deleteAllMeasurements() {
        Task {
            do {
                try await storageManager.performInBackgroundContext { context in
                    let allMeasurementsRequest = DBPerformanceMeasurement.fetchRequest()

                    try context
                        .fetch(allMeasurementsRequest)
                        .compactMap { $0 as? DBPerformanceMeasurement }
                        .forEach { context.delete($0) }

                    try context.saveOrRollback()
                }
            } catch {
                Log.error(error: error, domain: .metrics)
            }
        }
    }

    func record(measurement: PerformanceMeasurementEvent) {
        Task {
            do {
                try await storageManager.performInBackgroundContext { [self] context in
                    let databaseMeasurement = getNewOrExistingMeasurement(
                        for: measurement.operationId,
                        with: storageManager,
                        in: context
                    )

                    databaseMeasurement.update(from: measurement)
                    compactIfNeeded()

                    try context.saveOrRollback()
                }
            } catch {
                Log.error(error: error, domain: .metrics)
            }
        }
    }

    func getLastMeasurement(for operationId: String) async throws -> PerformanceMeasurementEvent? {
        let fetchRequest = DBPerformanceMeasurement.fetchRequest() as! NSFetchRequest<DBPerformanceMeasurement>
        fetchRequest.predicate = NSPredicate(format: "self.operationId == %@", operationId)
        fetchRequest.fetchLimit = 1

        return try await storageManager.performInBackgroundContext { context in
            let measurement: [DBPerformanceMeasurement] = try context.fetch(fetchRequest)
            return try measurement.first.flatMap { try $0.toDomain() }
        }
    }

    func fetchUnreportedMeasurements(
        for type: PerformanceOperationType
    ) async throws -> [PerformanceMeasurementEvent] {
        return try await storageManager.performInBackgroundContext { context in
            let events = try context.fetch(Self.makeUnreportedFetchRequest(operationTypeFilter: type))
            return try events.compactMap { try $0.toDomain() }
        }
    }

    func markAsReported(_ measurements: [PerformanceMeasurementEvent]) async throws {
        let fetchRequest = DBPerformanceMeasurement.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "self.operationId IN %@", measurements.map(\.operationId))

        return try await storageManager.performInBackgroundContext { context in
            guard let events = try context.fetch(fetchRequest) as? [DBPerformanceMeasurement] else {
                return
            }

            events.forEach {
                $0.isReported = true
            }

            try context.saveOrRollback()
        }
    }
}

private extension DBPerformanceMeasurementRepository {
    static func makeUnreportedFetchRequest(
        operationTypeFilter: PerformanceOperationType? = nil
    ) -> NSFetchRequest<DBPerformanceMeasurement> {
        let fetchRequest = DBPerformanceMeasurement.fetchRequest() as! NSFetchRequest<DBPerformanceMeasurement>

        if let operationTypeFilter {
            fetchRequest.predicate = NSCompoundPredicate(
                andPredicateWithSubpredicates: [
                    NSPredicate(format: "self.isReported == NO"),
                    NSPredicate(format: "self.operationType == %@", operationTypeFilter.rawValue)
                ]
            )
        } else {
            fetchRequest.predicate = NSPredicate(format: "self.isReported == NO")
        }

        fetchRequest.sortDescriptors = [
            NSSortDescriptor(key: "operationType", ascending: true),
            NSSortDescriptor(key: "timestamp", ascending: false)
        ]

        return fetchRequest
    }

    func getNewOrExistingMeasurement(
        for operationId: String,
        with storageManager: StorageManagerProtocol,
        in context: NSManagedObjectContext
    ) -> DBPerformanceMeasurement {
        let fetchRequest = DBPerformanceMeasurement.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "self.operationId == %@", operationId)

        guard
            let fetchedItems = try? context.fetch(fetchRequest),
            let existingMeasurement = fetchedItems.first as? DBPerformanceMeasurement
        else {
            let newMeasurement: DBPerformanceMeasurement = storageManager.new(with: operationId, by: "operationId", in: context)
            context.insert(newMeasurement)

            return newMeasurement
        }

        return existingMeasurement
    }

    func compactIfNeeded() {
        Task {
            do {
                try await storageManager.performInBackgroundContext { context in
                    let allMeasurementsRequest = DBPerformanceMeasurement.fetchRequest()

                    if try context.count(for: allMeasurementsRequest) > Config.maxEntryCount {
                        let reportedItemsRequest = DBPerformanceMeasurement.fetchRequest()
                        reportedItemsRequest.predicate = NSPredicate(format: "self.isReported == YES")

                        try context
                            .fetch(reportedItemsRequest)
                            .compactMap { $0 as? DBPerformanceMeasurement }
                            .forEach { context.delete($0) }

                        try context.saveOrRollback()
                    }
                }
            } catch {
                Log.error(error: error, domain: .metrics)
            }
        }
    }
}
