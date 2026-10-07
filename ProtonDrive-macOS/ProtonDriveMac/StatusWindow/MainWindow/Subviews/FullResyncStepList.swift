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
import PDLocalization

/// The ordered phases of a full resync. V1 (no discovery pass) omits `.discovering`.
enum FullResyncStepKind: Hashable {
    case discovering
    case downloading
    case applyingUpdates
    case refreshingDetails

    /// Present-continuous label with a trailing ellipsis, shown while the phase is the active
    /// (current or paused) step, e.g. "Finding your files…".
    var activeTitle: String {
        switch self {
        case .discovering: Localization.full_resync_step_discovering
        case .downloading: Localization.full_resync_step_downloading
        case .applyingUpdates: Localization.full_resync_step_applying
        case .refreshingDetails: Localization.full_resync_step_refreshing
        }
    }

    /// Imperative label shown while the phase is upcoming, done, or failed, e.g. "Find your files".
    var baseTitle: String {
        switch self {
        case .discovering: Localization.full_resync_step_discover
        case .downloading: Localization.full_resync_step_download
        case .applyingUpdates: Localization.full_resync_step_apply
        case .refreshingDetails: Localization.full_resync_step_refresh
        }
    }
}

/// One row in the resync step list: a phase, its status, and — only while current — its inline progress.
struct FullResyncStep: Equatable, Identifiable {

    /// Row status, in lifecycle order. `failed`/`paused` mark the phase a terminal resync stopped on.
    enum Status: Equatable {
        case done       // passed; grey tick, greyed title
        case current    // active; spinner icon, accent title, inline detail
        case upcoming   // not started; light title, dot icon
        case failed     // resync errored on this phase
        case paused     // resync paused on this phase
    }

    /// Inline progress shown beneath the current row.
    enum StepDetail: Equatable {
        /// Indeterminate bar with a running count (e.g. "N found").
        case indeterminate(count: Int)
        /// Determinate bar, "x of y".
        case determinate(x: Int, y: Int)
        /// A bare spinner while `processed == 0`, then a running "N processed".
        case spinnerOrCount(processed: Int)
    }

    let kind: FullResyncStepKind
    /// 1-based position within the current variant's step list (e.g. "Step 3").
    let number: Int
    let status: Status
    let detail: StepDetail?

    var id: FullResyncStepKind { kind }

    /// The active step (current/paused) shows the present-continuous title; done, upcoming, and failed
    /// steps show the imperative title.
    var title: String {
        switch status {
        case .current, .paused: kind.activeTitle
        case .done, .upcoming, .failed: kind.baseTitle
        }
    }
}

/// Maps the resync engine signals `(variant, state, furthestStep)` to the ordered step list the UI renders.
/// Pure: same inputs always produce the same output, so the mapping is unit-testable in isolation.
enum FullResyncStepList {

    /// The ordered phases for a variant. V1 has no discovery phase.
    static func kinds(for variant: ApplicationState.FullResyncVariant) -> [FullResyncStepKind] {
        switch variant {
        case .v1: [.downloading, .applyingUpdates, .refreshingDetails]
        case .v2: [.discovering, .downloading, .applyingUpdates, .refreshingDetails]
        }
    }

    /// - Parameter stepDetails: each phase's last-seen detail, so finished phases keep showing their final
    ///   progress. Passed through for `done`/`failed`/`paused` rows; the current row uses its live detail.
    static func steps(variant: ApplicationState.FullResyncVariant,
                      state: ApplicationState.FullResyncState,
                      furthestStep: Int,
                      stepDetails: [FullResyncStepKind: FullResyncStep.StepDetail] = [:]) -> [FullResyncStep] {
        let kinds = kinds(for: variant)
        switch state {
        case .idle, .starting:
            // Nothing has started (or the step list isn't shown yet): all upcoming.
            return kinds.enumerated().map { FullResyncStep(kind: $1, number: $0 + 1, status: .upcoming, detail: nil) }
        case .completed:
            // Not rendered: a completed resync returns to the file list with a banner, so `fullResyncState`'s
            // didSet has already reset the variant and cleared the retained details. Values would be nil
            // anyway, so the shape is all-done with no detail.
            return kinds.enumerated().map { FullResyncStep(kind: $1, number: $0 + 1, status: .done, detail: nil) }
        case .errored:
            return marking(kinds: kinds, index: furthestStep, as: .failed, stepDetails: stepDetails)
        case .paused:
            return marking(kinds: kinds, index: furthestStep, as: .paused, stepDetails: stepDetails)
        case .inProgress, .enumerating:
            guard let active = activeStep(variant: variant, state: state) else {
                return kinds.enumerated().map { FullResyncStep(kind: $1, number: $0 + 1, status: .upcoming, detail: nil) }
            }
            return advancing(kinds: kinds, current: active.kind, detail: active.detail, stepDetails: stepDetails)
        }
    }

    /// The active step (current phase) and its live detail, or nil when idle/terminal. Used both to build
    /// the current row and to retain each phase's latest detail (so a finished phase keeps showing it).
    static func activeStep(variant: ApplicationState.FullResyncVariant,
                           state: ApplicationState.FullResyncState)
        -> (kind: FullResyncStepKind, detail: FullResyncStep.StepDetail)? {
        switch state {
        case let .inProgress(saved, total):
            let phase = downloadPhase(variant: variant, saved: saved, total: total)
            return (kind: phase.0, detail: phase.1)
        case let .enumerating(enumeratingState):
            let phase = enumerationPhase(enumeratingState)
            return (kind: phase.0, detail: phase.1)
        case .idle, .starting, .completed, .errored, .paused:
            return nil
        }
    }

    // MARK: - Phase resolution

    /// The current step during the download/scan phase. A known total means downloading with determinate
    /// progress; an unknown total under v2 is still discovering; v1 (no discovery) shows an indeterminate
    /// download until it finishes.
    private static func downloadPhase(variant: ApplicationState.FullResyncVariant,
                                      saved: Int,
                                      total: Int?) -> (FullResyncStepKind, FullResyncStep.StepDetail) {
        // Downloading has begun only once at least one item's metadata is saved. Before that — including the
        // instant discovery ends and the total first becomes known (saved == 0) — the resync is still
        // discovering, so a failure at that boundary is attributed to discovery, not to a download that never
        // produced anything.
        if let total, saved > 0 {
            return (.downloading, .determinate(x: saved, y: total))
        }
        switch variant {
        case .v2: return (.discovering, .indeterminate(count: total ?? saved))
        case .v1: return (.downloading, .indeterminate(count: saved))
        }
    }

    /// The current step during enumeration. The working-set wait is "Applying updates" until its total is
    /// known to be 0 (nothing to apply), at which point applying is done and the refresh pass is current.
    private static func enumerationPhase(_ state: ApplicationState.FullResyncState.EnumeratingState)
        -> (FullResyncStepKind, FullResyncStep.StepDetail) {
        switch state {
        case let .waitingForTheWorkingSetEnumerationToFinish(_, enumerated, total):
            guard let total else {
                // Total not reported yet: indeterminate applying.
                return (.applyingUpdates, .indeterminate(count: enumerated))
            }
            if total == 0 {
                // Nothing to apply: applying is done, so the current row is already the refresh pass.
                return (.refreshingDetails, .spinnerOrCount(processed: 0))
            }
            return (.applyingUpdates, .determinate(x: enumerated, y: total))
        case .waitingForTheFetchItemPass:
            return (.refreshingDetails, .spinnerOrCount(processed: 0))
        case let .fetchItemPassInProgress(_, fetched, _):
            return (.refreshingDetails, .spinnerOrCount(processed: fetched))
        }
    }

    // MARK: - List assembly

    /// Marks `current` as `.current` (with its live `detail`), earlier phases `.done` (with their retained
    /// detail), later phases `.upcoming`.
    private static func advancing(kinds: [FullResyncStepKind],
                                  current: FullResyncStepKind,
                                  detail: FullResyncStep.StepDetail,
                                  stepDetails: [FullResyncStepKind: FullResyncStep.StepDetail]) -> [FullResyncStep] {
        guard let currentIndex = kinds.firstIndex(of: current) else {
            return kinds.enumerated().map { FullResyncStep(kind: $1, number: $0 + 1, status: .upcoming, detail: nil) }
        }
        return kinds.enumerated().map { index, kind in
            if index < currentIndex {
                return FullResyncStep(kind: kind, number: index + 1, status: .done, detail: stepDetails[kind])
            } else if index == currentIndex {
                return FullResyncStep(kind: kind, number: index + 1, status: .current, detail: detail)
            } else {
                return FullResyncStep(kind: kind, number: index + 1, status: .upcoming, detail: nil)
            }
        }
    }

    /// Marks the phase at `index` with a terminal `status` (keeping its retained detail), earlier phases
    /// `.done` (with retained detail), later `.upcoming`. `index` is clamped so a stale furthest-step
    /// index can't drop a row.
    private static func marking(kinds: [FullResyncStepKind],
                                index: Int,
                                as status: FullResyncStep.Status,
                                stepDetails: [FullResyncStepKind: FullResyncStep.StepDetail]) -> [FullResyncStep] {
        let marked = min(max(index, 0), kinds.count - 1)
        return kinds.enumerated().map { position, kind in
            if position < marked {
                return FullResyncStep(kind: kind, number: position + 1, status: .done, detail: stepDetails[kind])
            } else if position == marked {
                return FullResyncStep(kind: kind, number: position + 1, status: status, detail: stepDetails[kind])
            } else {
                return FullResyncStep(kind: kind, number: position + 1, status: .upcoming, detail: nil)
            }
        }
    }
}
