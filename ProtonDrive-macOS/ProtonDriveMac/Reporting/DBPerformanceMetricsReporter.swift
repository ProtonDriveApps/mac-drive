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

protocol PerformanceMetricsReporter {
    func startReporting()
    func finishReporting()
}

final class DBPerformanceMetricsReporter: PerformanceMetricsReporter {
    enum Constants {
        static let reportingCycleLength: TimeInterval = .init(60)
        static let inactivityTimeout: TimeInterval = .init(10)
    }

    private var inactivityTimeout: PausableTimerResource
    private var reportingCycle: PausableTimerResource
    private var cancellables: [AnyCancellable] = []

    private let repository: PeformanceMeasurementRepository
    private let uploadResource: UploadSpeedMetricResource
    private let downloadResource: DownloadSpeedMetricResource
    private let dateResource: DateResource

    init(
        repository: PeformanceMeasurementRepository,
        uploadResource: UploadSpeedMetricResource,
        downloadResource: DownloadSpeedMetricResource,
        dateResource: DateResource,
        inactivityTimer: PausableTimerResource,
        reportingCycleTimer: PausableTimerResource
    ) {
        self.repository = repository
        self.uploadResource = uploadResource
        self.downloadResource = downloadResource
        self.dateResource = dateResource
        self.inactivityTimeout = inactivityTimer
        self.reportingCycle = reportingCycleTimer
    }

    convenience init() {
        self.init(
            repository: DBPerformanceMeasurementRepository(),
            uploadResource: ObservabilityUploadSpeedMetricResource(),
            downloadResource: ObservabilityDownloadSpeedMetricResource(),
            dateResource: PlatformCurrentDateResource(),
            inactivityTimer: CommonRunLoopPausableTimerResource(
                duration: Constants.inactivityTimeout
            ),
            reportingCycleTimer: CommonRunLoopPausableTimerResource(
                duration: Constants.reportingCycleLength
            )
        )
    }

    // MARK: - Lifecycle

    func startReporting() {
        Log.trace()

        #if !HAS_QA_FEATURES
            repository.deleteAllMeasurements()
        #endif

        self.reportingCycle.restart()
        self.inactivityTimeout.restart()

        repository.unreportedMeasurementPublisher.sink { [weak self] events in
            self?.restartTimersIfNeeded()
        }.store(in: &cancellables)

        inactivityTimeout.updatePublisher.sink { [weak self] in
            self?.stopTimers()
            self?.reportIfNeeded()
        }.store(in: &cancellables)

        reportingCycle.updatePublisher.sink { [weak self] in
            self?.reportIfNeeded()
        }.store(in: &cancellables)
    }

    func finishReporting() {
        Log.trace()

        self.reportingCycle.stop()
        self.inactivityTimeout.stop()

        reportIfNeeded()

        cancellables.forEach { $0.cancel() }
    }
}

private extension DBPerformanceMetricsReporter {
    // MARK: - Timer helpers

    func restartTimersIfNeeded() {
        if !reportingCycle.isRunning {
            reportingCycle.restart()
        }

        if !inactivityTimeout.isRunning {
            inactivityTimeout.restart()
        }
    }

    func stopTimers() {
        inactivityTimeout.stop()
        reportingCycle.stop()
    }

    // MARK: - Reporting

    func reportIfNeeded() {
        Log.trace()

        Task { [self] in
            do {
                let measurements = try [
                    PerformanceOperationType.upload: await repository.fetchUnreportedMeasurements(for: .upload),
                    PerformanceOperationType.download: await repository.fetchUnreportedMeasurements(for: .download)
                ]

                let hasMeasurements = measurements.values.contains { !$0.isEmpty }
                guard hasMeasurements else { return }

                // prepare report: segmented by opreration then by pipeline for ease of reporting
                let report = measurements.mapValues { makePerPipelineReport(measurements: $0) }

                report.forEach { operation, perPipelineReport in
                    switch operation {
                    case .download:
                        perPipelineReport.forEach { pipeline, speed in
                            downloadResource.sendMetric(
                                speed: speed,
                                isBackground: true,
                                pipeline: pipeline
                            )
                        }
                    case .upload:
                        perPipelineReport.forEach { pipeline, speed in
                            uploadResource.sendMetric(
                                speed: speed,
                                isBackground: true,
                                pipeline: pipeline
                            )
                        }
                    }
                }

                try await repository.markAsReported(measurements.values.flatMap { $0 })
            } catch {
                Log.error(error: error, domain: .metrics)
            }
        }
    }

    func makePerPipelineReport(measurements: [PerformanceMeasurementEvent]) -> [DriveObservabilityPipeline: Int] {
        Log.trace()

        // Ideally we'll only ever see one pipeline, but we handle the case where more than one.
        let groupedByPipeline = Dictionary(grouping: measurements, by: \.pipeline)

        return groupedByPipeline.mapValues {
            calculateSpeed(measurements: $0)
        }
    }

    func calculateSpeed(measurements: [PerformanceMeasurementEvent]) -> Int {
        Log.trace()

        let measurementTimeRange = getMeasurementTimeRange(from: measurements)
        let measuredBytes = measurements.map(\.progressInBytes).reduce(0) { $0 + $1 }
        let speedInKib = Double(measuredBytes) / (Double(1024) * measurementTimeRange)

        return Int(round(speedInKib))
    }

    func getMeasurementTimeRange(from measurements: [PerformanceMeasurementEvent]) -> TimeInterval {
        // We expect the measurements to already be sorted by timestamp.
        // This is done via sortDescriptor in the repository.

        if measurements.count >= 2 {
            let measurementTimes = measurements.map(\.timestamp)
            return measurementTimes[0] - measurementTimes[measurements.count - 1]
        } else if measurements.count == 1 {
            // It's unexpected that we'll reach this sceneario - the collector should always
            // write at least a pair of events to the database: a start event with 0 progress,
            // progress updates (these are optional though) and an end event with the remaining
            // progress when the file upload completes.

            // If we only have a single measurement, we use the distance to current time
            // as its duration; the worst case scenario here (a single very small file), we'll divide
            // its size by ~timeout.
            Log.warning("Measurement issue: attempting to calculate time range for single measurement", domain: .metrics)
            let distanceToCurrentTime = measurements[0].timestamp.distance(to: dateResource.getDate().timeIntervalSinceReferenceDate)

            return distanceToCurrentTime == .zero ? 1 : distanceToCurrentTime
        } else {
            // We've guaranteed earlier in the call chain that we'd have
            // at least one element in the measurements list.
            Log.error("Measuring error: attempted to calculate time range for empty set of measurements", domain: .metrics)
            return 1
        }
    }
}
