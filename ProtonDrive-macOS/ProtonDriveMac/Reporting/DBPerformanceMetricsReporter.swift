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
    private let reportAggregator: PerformanceMetricsReportAggregating
    private let shouldCleanOnStartup: Bool

    init(
        repository: PeformanceMeasurementRepository,
        uploadResource: UploadSpeedMetricResource,
        downloadResource: DownloadSpeedMetricResource,
        inactivityTimer: PausableTimerResource,
        reportingCycleTimer: PausableTimerResource,
        reportAggregator: PerformanceMetricsReportAggregating,
        shouldCleanOnStartup: Bool
    ) {
        self.repository = repository
        self.uploadResource = uploadResource
        self.downloadResource = downloadResource
        self.inactivityTimeout = inactivityTimer
        self.reportingCycle = reportingCycleTimer
        self.reportAggregator = reportAggregator
        self.shouldCleanOnStartup = shouldCleanOnStartup
    }

    convenience init() {
        self.init(
            repository: DBPerformanceMeasurementRepository(),
            uploadResource: ObservabilityUploadSpeedMetricResource(),
            downloadResource: ObservabilityDownloadSpeedMetricResource(),
            inactivityTimer: CommonRunLoopPausableTimerResource(
                duration: Constants.inactivityTimeout
            ),
            reportingCycleTimer: CommonRunLoopPausableTimerResource(
                duration: Constants.reportingCycleLength
            ),
            reportAggregator: PerformanceMetricsReportAggregator(),
            shouldCleanOnStartup: Self.shouldClearOldMeasurementsByDefault()
        )
    }

    // MARK: - Lifecycle

    func startReporting() {
        Log.trace()

        if self.shouldCleanOnStartup {
            repository.deleteAllMeasurements()
        }

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
        cancellables = []
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

                let report = reportAggregator.buildReport(from: measurements)

                guard !report.isEmpty else { return }

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

    // MARK: - Static helpers
    private static func shouldClearOldMeasurementsByDefault() -> Bool {
        #if HAS_QA_FEATURES
            return false
        #else
            return true
        #endif
    }
}
