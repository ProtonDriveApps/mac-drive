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

import Dispatch
import Foundation
import PDCore

/// Run-level metrics for one full resync, preserved across retry/pause/resume so its state survives the
/// per-attempt recreation of the resync work.
final class FullResyncRunMetrics {
    private let reporter: FullResyncMetricsReporting
    private let dateResource: DateResource
    private var userAction: DriveFullResyncUserAction = .firstTry
    private var engine: ScanEngineVersion = .v1
    private var step: DriveFullResyncStep = .metadataFetch
    private(set) var finalNodeTotal: Int = 0
    private var finalActiveCount: Int = 0
    private var firstStartTime: Date?
    private var didConcludeTime = false
    private var statePropagationStart: DispatchTime?

    init(reporter: FullResyncMetricsReporting, dateResource: DateResource) {
        self.reporter = reporter
        self.dateResource = dateResource
    }

    func attemptWillStart(userAction: DriveFullResyncUserAction) {
        self.userAction = userAction
        step = .metadataFetch
        if firstStartTime == nil {
            firstStartTime = dateResource.getDate()
        }
    }

    func scanDidStart(engine: ScanEngineVersion) {
        self.engine = engine
    }

    func enterStatePropagation(finalNodeTotal: Int, activeNodeCount: Int = 0) {
        step = .statePropagation
        self.finalNodeTotal = finalNodeTotal
        finalActiveCount = activeNodeCount
        statePropagationStart = DispatchTime.now()
    }

    var settledNodeCount: Int { finalActiveCount }

    func reportSucceeded() {
        reporter.reportResult(result: .succeeded, userAction: userAction, engine: engine, step: .statePropagation)
        concludeTime(.completed)
    }

    func reportFailed() {
        reporter.reportResult(result: .failed, userAction: userAction, engine: engine, step: step)
    }

    func reportCancelled() {
        reporter.reportResult(result: .cancelled, userAction: userAction, engine: engine, step: step)
        concludeTime(.aborted)
    }

    func reportError(_ type: DriveFullResyncErrorType) {
        reporter.reportError(type: type, engine: engine)
    }

    /// nodeCount is the settled count on a confirmed enumeration, else the partial fetched-item count.
    func reportStatePropagationSpeed(nodeCount: Int) {
        guard let statePropagationStart else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - statePropagationStart.uptimeNanoseconds) / 1_000_000_000
        reporter.reportSpeed(step: .statePropagation, engine: engine, nodeCount: nodeCount, elapsed: elapsed)
    }

    /// Time histogram, once per run. Errors don't conclude here — a retry may still follow.
    func concludeTime(_ result: DriveFullResyncTimeResult) {
        guard !didConcludeTime, let firstStartTime else { return }
        didConcludeTime = true
        // Wall-clock duration can be negative (clock moved back) or huge (clock jump); clamp before Int() so
        // it can't emit a negative value or trap on overflow.
        let rawMinutes = (dateResource.getDate().timeIntervalSince(firstStartTime) / 60).rounded()
        let minutes = rawMinutes.isFinite ? Int(min(max(rawMinutes, 0), Double(Int32.max))) : 0
        reporter.reportTime(minutes: minutes, result: result, size: Self.size(nodeCount: finalNodeTotal), engine: engine)
    }

    /// Flushes a started-but-never-concluded run (e.g. errored, never retried) as aborted.
    func flushAbandonedIfNeeded() {
        guard firstStartTime != nil, !didConcludeTime else { return }
        concludeTime(.aborted)
    }

    private static func size(nodeCount: Int) -> DriveFullResyncSize {
        switch nodeCount {
        case ..<10_000: return .upTo10k
        case ..<100_000: return .tenK100k
        case ..<1_000_000: return .hundredK1000k
        default: return .moreThan1000k
        }
    }
}
