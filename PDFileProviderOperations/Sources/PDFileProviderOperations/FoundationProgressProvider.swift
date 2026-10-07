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
import Combine
import Foundation
import PDCore
import PDFileProvider

/// Observes Foundation progress, normalizes it, and throttles active updates for a `GlobalProgressProvider` consumer.
public final class FoundationProgressProvider: GlobalProgressProvider {
    private let downloadProgress: Progress
    private let uploadProgress: Progress
    private let interval: DispatchQueue.SchedulerTimeType.Stride
    private let queue: DispatchQueue
    // Scheduled actions must execute on the publication queue.
    private let scheduler: AnySchedulerOf<DispatchQueue>
    private let normalizer: any GlobalProgressNormalizer
    private let queueKey = DispatchSpecificKey<Bool>()
    // Capture and enqueue together: concurrent KVO callbacks must not reorder snapshots.
    private let observationLock = NSRecursiveLock()

    private var observations: [NSKeyValueObservation] = []
    private var lastSeen = GlobalProgress.idle
    private var lastPublished = GlobalProgress.idle
    private var lastPublishedAt: DispatchQueue.SchedulerTimeType?
    private var onProgressPublished: ((GlobalProgress) -> Void)?
    private var trailingID: UUID?
    private var isStopped = false

    public convenience init(
        downloadProgress: Progress,
        uploadProgress: Progress,
        interval: TimeInterval = 0.5,
        queue: DispatchQueue
    ) {
        self.init(
            downloadProgress: downloadProgress,
            uploadProgress: uploadProgress,
            interval: interval,
            queue: queue,
            scheduler: queue.eraseToAnyScheduler(),
            normalizer: FoundationGlobalProgressNormalizer()
        )
    }

    init(
        downloadProgress: Progress,
        uploadProgress: Progress,
        interval: TimeInterval,
        queue: DispatchQueue,
        scheduler: AnySchedulerOf<DispatchQueue>,
        normalizer: any GlobalProgressNormalizer = FoundationGlobalProgressNormalizer()
    ) {
        self.downloadProgress = downloadProgress
        self.uploadProgress = uploadProgress
        self.interval = .seconds(interval)
        self.queue = queue
        self.scheduler = scheduler
        self.normalizer = normalizer
        queue.setSpecific(key: queueKey, value: true)
    }

    public func startObservingProgress(
        onProgressPublished: @escaping (GlobalProgress) -> Void
    ) {
        let start = {
            guard !self.isStopped, self.onProgressPublished == nil else { return }
            self.onProgressPublished = onProgressPublished
            self.observationLock.withLock {
                self.observations = [self.downloadProgress, self.uploadProgress].flatMap(self.observe)
                self.lastSeen = self.normalized()
                self.logFirstAggregate(normalized: self.lastSeen)
                self.publish(self.lastSeen)
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) == true {
            start()
        } else {
            queue.sync(execute: start)
        }
    }

    public func stopObservingProgress() {
        let stop = {
            guard !self.isStopped else { return }
            self.isStopped = true
            self.observations.removeAll()
            self.cancelPendingPublication()
            self.onProgressPublished = nil
        }
        if DispatchQueue.getSpecific(key: queueKey) == true {
            stop()
        } else {
            queue.sync(execute: stop)
        }
    }

    private func observe(
        _ progress: Progress
    ) -> [NSKeyValueObservation] {
        func observe<Value>(
            _ keyPath: KeyPath<Progress, Value>
        ) -> NSKeyValueObservation {
            progress.observe(keyPath) { [weak self] _, _ in
                guard let self else { return }
                observationLock.withLock {
                    let value = self.normalized()
                    self.queue.async { [weak self] in self?.handleObservedProgress(value) }
                }
            }
        }
        // Only KVO-safe keys; file counts are covered by the description signal.
        return [
            observe(\.localizedDescription), observe(\.fractionCompleted),
            observe(\.totalUnitCount), observe(\.completedUnitCount),
            observe(\.isFinished), observe(\.isIndeterminate), observe(\.isCancelled),
        ]
    }

    private func handleObservedProgress(
        _ value: GlobalProgress
    ) {
        guard !isStopped else { return }
        guard value != lastSeen else { return }
        let previous = lastSeen
        lastSeen = value

        guard value.isActive, previous.isActive else {
            publish(value)
            return
        }
        guard trailingID == nil else { return }
        guard let lastPublishedAt else {
            publish(value)
            return
        }
        let deadline = lastPublishedAt.advanced(by: interval)
        guard deadline > scheduler.now else {
            publish(value)
            return
        }
        let id = UUID()
        trailingID = id
        scheduler.schedule(
            after: deadline,
            tolerance: .zero,
            options: nil
        ) { [weak self] in
            // Logical cancellation must not clear a newer publication's deadline.
            guard let self, !isStopped, trailingID == id else { return }
            trailingID = nil
            if lastSeen != lastPublished { publish(lastSeen) }
        }
    }

    private func publish(_ value: GlobalProgress) {
        cancelPendingPublication()
        lastPublished = value
        lastPublishedAt = scheduler.now
        onProgressPublished?(value)
    }

    private func cancelPendingPublication() {
        trailingID = nil
    }

    private func normalized() -> GlobalProgress {
        normalizer.normalize(
            downloadProgress: downloadProgress,
            uploadProgress: uploadProgress
        )
    }

    private func logFirstAggregate(
        normalized: GlobalProgress
    ) {
        func describe(_ progress: Progress) -> String {
            let files = progress.fileTotalCount.map(String.init) ?? "nil"
            let completedFiles = progress.fileCompletedCount.map(String.init) ?? "nil"
            return "files \(completedFiles)/\(files) bytes \(progress.completedUnitCount)/\(progress.totalUnitCount)"
                + " finished \(progress.isFinished) cancelled \(progress.isCancelled)"
        }

        Log.info(
            "Acquired global progress — upload \(describe(uploadProgress)),"
                + " download \(describe(downloadProgress)), normalized \(normalized.logDescription)",
            domain: .fileProvider
        )
    }
}

private extension GlobalProgress {
    var isActive: Bool {
        if case .active = self { true } else { false }
    }
}
