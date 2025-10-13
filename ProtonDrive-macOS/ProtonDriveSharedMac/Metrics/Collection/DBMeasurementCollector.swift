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
import Foundation
import PDCore
import PDFileProviderOperations
import ProtonCoreUtilities

final class DBPerformanceMeasurementCollector: ProgressPerformanceCollector {
    public let hasOperations: AnyPublisher<Bool, Never>

    private let operationType: PerformanceOperationType
    private var progresses: Atomic<[Progress: UUID]> = Atomic([:])
    private var cancellables: [UUID: AnyCancellable] = [:]
    private let progressCountSubject = CurrentValueSubject<Int, Never>(0)

    private let repository: PeformanceMeasurementRepository
    private let dateResource: DateResource

    init(
        operationType: PerformanceOperationType,
        repository: PeformanceMeasurementRepository,
        dateResource: DateResource
    ) {
        self.operationType = operationType

        self.repository = repository
        self.dateResource = dateResource

        self.hasOperations = progressCountSubject
            .map { $0 > 0 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    convenience init(operationType: PerformanceOperationType) {
        self.init(
            operationType: operationType,
            repository: DBPerformanceMeasurementRepository(),
            dateResource: PlatformCurrentDateResource()
        )
    }

    func startObserving(progress: Progress, using pipeline: DriveObservabilityPipeline) {
        Log.trace()

        let taskID = UUID()

        progresses.mutate { $0.updateValue(taskID, forKey: progress) }
        progressCountSubject.send(progresses.fetch(\.count))

        // Upload progress events are optional: these will only be reliably sent for
        // large files.
        let cancellable = progress.publisher(for: \.completedUnitCount)
            .scan((previous: Int64(0), current: Int64(0))) { previousState, newValue in
                (previous: previousState.current, current: newValue)
            }
            .sink { [weak self] state in
                guard let self else { return }
                let change = state.current - state.previous
                guard change > 0 else { return }

                repository.record(
                    measurement: PerformanceMeasurementEvent(
                        operationId: taskID.uuidString,
                        timestamp: dateResource.getDate().timeIntervalSinceReferenceDate,
                        pipeline: pipeline,
                        operationType: operationType,
                        progressInBytes: change,
                        isReported: false
                    )
                )
            }

        cancellables[taskID] = cancellable
    }

    func finishObserving(progress: Progress, using pipeline: DriveObservabilityPipeline) {
        Log.trace()
        let timestamp = dateResource.getDate().timeIntervalSinceReferenceDate

        Task {
            guard let taskID = progresses.value[progress] else {
                Log.warning("Failed to get taskID for running Progress, did reportUploadComplete get double called?", domain: .fileProvider)
                return
            }

            let lastProgress = try? await repository.getLastMeasurement(for: taskID.uuidString)?.progressInBytes

            progresses.mutate { dict in
                let fileSize: Int64 = progress.totalUnitCount

                repository.record(
                    measurement: PerformanceMeasurementEvent(
                        operationId: taskID.uuidString,
                        timestamp: timestamp,
                        pipeline: pipeline,
                        operationType: operationType,
                        progressInBytes: fileSize - (lastProgress ?? 0),
                        isReported: false
                    )
                )

                cancellables[taskID]?.cancel()

                dict[progress] = nil
                return
            }
        }
    }
}
