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
        static let bufferFlushCount = 50
        static let timerIntervalSeconds: Double? = 30
    }

    private static let sharedStorage = GenericStorageManager(
        bundle: Bundle(for: DBPerformanceMeasurementRepository.self),
        suite: .group(named: Constants.appContainerGroup),
        databaseName: "Metrics"
    )

    private let storageManager: StorageManagerProtocol
    private let measurementObserver: FetchedResultObserver<DBPerformanceMeasurement>

    // Buffer guarded by lock. Crash before flush = acceptable loss for perf metrics.
    private let bufferLock = NSLock()
    private var pendingMeasurements: [PerformanceMeasurementEvent] = []
    private var flushingMeasurements: [PerformanceMeasurementEvent] = []
    private var currentFlushTask: Task<Void, Never>?

    private var flushTimer: DispatchSourceTimer?
    private let bufferFlushCount: Int
    private let timerIntervalSeconds: Double?

    var unreportedMeasurementPublisher: AnyPublisher<[PerformanceMeasurementEvent], Never> {
        measurementObserver.itemPublisher
    }

    init(
        storageManager: StorageManagerProtocol,
        measurementObserver: FetchedResultObserver<DBPerformanceMeasurement>,
        bufferFlushCount: Int = Config.bufferFlushCount,
        timerIntervalSeconds: Double? = Config.timerIntervalSeconds
    ) {
        self.storageManager = storageManager
        self.measurementObserver = measurementObserver
        self.bufferFlushCount = max(1, bufferFlushCount)
        self.timerIntervalSeconds = timerIntervalSeconds
        startFlushTimer()
    }

    public convenience init() {
        self.init(
            storageManager: Self.sharedStorage,
            measurementObserver: FetchedResultObserver(
                fetchRequest: Self.makeUnreportedFetchRequest(),
                context: Self.sharedStorage.backgroundContext
            )
        )
    }

    deinit {
        flushTimer?.cancel()
        flushTimer = nil
        // Best-effort flush of remaining buffered measurements on teardown.
        let remaining = drainAllBufferedMeasurementsForFlush()
        if !remaining.isEmpty {
            let storageManager = self.storageManager
            Task {
                await Self.persist(
                    measurements: remaining,
                    storageManager: storageManager,
                    maxEntryCount: Config.maxEntryCount
                )
            }
        }
    }

    func deleteAllMeasurements() {
        bufferLock.lock()
        pendingMeasurements.removeAll()
        bufferLock.unlock()

        Task {
            do {
                try await storageManager.performInBackgroundContext { context in
                    let allMeasurementsRequest = Self.makeEntityNameFetchRequest()

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
        bufferLock.lock()
        pendingMeasurements.append(measurement)
        let shouldFlush = pendingMeasurements.count >= bufferFlushCount
        let toFlush = shouldFlush ? drainPendingMeasurementsForFlushLocked() : []
        bufferLock.unlock()

        if shouldFlush {
            scheduleFlush(for: toFlush)
        }
    }

    func getLastMeasurement(for operationId: String) async throws -> PerformanceMeasurementEvent? {
        let buffered = latestBufferedMeasurement(for: operationId)

        if let buffered {
            return buffered
        }

        let fetchRequest = Self.makeEntityNameFetchRequest()
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
        await flushBufferAsync()

        return try await storageManager.performInBackgroundContext { context in
            let events = try context.fetch(Self.makeUnreportedFetchRequest(operationTypeFilter: type))
            return try events.compactMap { try $0.toDomain() }
        }
    }

    func markAsReported(_ measurements: [PerformanceMeasurementEvent]) async throws {
        await flushBufferAsync()

        let fetchRequest = Self.makeEntityNameFetchRequest()
        fetchRequest.predicate = NSPredicate(format: "self.operationId IN %@", measurements.map(\.operationId))

        return try await storageManager.performInBackgroundContext { context in
            let events = try context.fetch(fetchRequest)

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
        let fetchRequest = makeEntityNameFetchRequest()

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
    
    static func createNewMeasurement(
        for operationId: String,
        with storageManager: StorageManagerProtocol,
        in context: NSManagedObjectContext
    ) -> DBPerformanceMeasurement {
        let newMeasurement: DBPerformanceMeasurement = storageManager.new(with: operationId, by: "operationId", in: context)
        context.insert(newMeasurement)
        return newMeasurement
    }

    func latestBufferedMeasurement(for operationId: String) -> PerformanceMeasurementEvent? {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        return (flushingMeasurements + pendingMeasurements)
            .reversed()
            .first(where: { $0.operationId == operationId })
    }

    /// Drains pending measurements while the lock is already held. Caller must hold `bufferLock`.
    func drainPendingMeasurementsForFlushLocked() -> [PerformanceMeasurementEvent] {
        let drained = pendingMeasurements
        pendingMeasurements.removeAll()
        flushingMeasurements.append(contentsOf: drained)
        return drained
    }

    func drainAllBufferedMeasurementsForFlush() -> [PerformanceMeasurementEvent] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return drainPendingMeasurementsForFlushLocked()
    }

    func scheduleFlush(for measurements: [PerformanceMeasurementEvent]) {
        guard !measurements.isEmpty else { return }

        bufferLock.lock()
        let previousFlushTask = currentFlushTask
        let storageManager = self.storageManager
        currentFlushTask = Task { [weak self] in
            await previousFlushTask?.value
            await Self.persist(
                measurements: measurements,
                storageManager: storageManager,
                maxEntryCount: Config.maxEntryCount
            )
            self?.finishFlushing(measurements)
        }
        bufferLock.unlock()
    }

    func flushBufferAsync() async {
        bufferLock.lock()
        let toFlush = drainPendingMeasurementsForFlushLocked()
        bufferLock.unlock()

        if !toFlush.isEmpty {
            scheduleFlush(for: toFlush)
        }

        let flushTask = currentFlushTaskSnapshot()
        await flushTask?.value
    }

    func finishFlushing(_ measurements: [PerformanceMeasurementEvent]) {
        bufferLock.lock()
        flushingMeasurements.removeFirst(min(measurements.count, flushingMeasurements.count))
        bufferLock.unlock()
    }

    func currentFlushTaskSnapshot() -> Task<Void, Never>? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return currentFlushTask
    }

    func startFlushTimer() {
        guard let timerIntervalSeconds, timerIntervalSeconds > 0 else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + timerIntervalSeconds, repeating: timerIntervalSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let toFlush = drainAllBufferedMeasurementsForFlush()
            scheduleFlush(for: toFlush)
        }
        timer.resume()
        flushTimer = timer
    }

    static func persist(
        measurements: [PerformanceMeasurementEvent],
        storageManager: StorageManagerProtocol,
        maxEntryCount: Int
    ) async {
        guard !measurements.isEmpty else { return }

        do {
            try await storageManager.performInBackgroundContext { context in
                for measurement in measurements {
                    let dbMeasurement = Self.createNewMeasurement(
                        for: measurement.operationId,
                        with: storageManager,
                        in: context
                    )
                    dbMeasurement.update(from: measurement)
                }

                try compactIfNeeded(storageManager: storageManager, maxEntryCount: maxEntryCount, context: context)
                try context.saveOrRollback()
            }
        } catch {
            Log.error(error: error, domain: .metrics)
        }
    }

    static func compactIfNeeded(
        storageManager: StorageManagerProtocol,
        maxEntryCount: Int,
        context: NSManagedObjectContext
    ) throws {
        let allMeasurementsRequest = makeEntityNameFetchRequest()

        if try context.count(for: allMeasurementsRequest) > maxEntryCount {
            let reportedItemsRequest = makeEntityNameFetchRequest()
            reportedItemsRequest.predicate = NSPredicate(format: "self.isReported == YES")

            try context
                .fetch(reportedItemsRequest)
                .compactMap { $0 as? DBPerformanceMeasurement }
                .forEach { context.delete($0) }
        }
    }

    static func makeEntityNameFetchRequest() -> NSFetchRequest<DBPerformanceMeasurement> {
        return NSFetchRequest<DBPerformanceMeasurement>(entityName: "DBPerformanceMeasurement")
    }
}
