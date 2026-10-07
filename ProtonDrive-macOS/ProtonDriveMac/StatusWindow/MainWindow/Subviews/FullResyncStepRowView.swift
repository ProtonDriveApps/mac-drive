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

import SwiftUI
import ProtonCoreUIFoundations
import PDLocalization

/// Renders one `FullResyncStep` as a row: a leading status glyph, the step title, and a trailing value.
///
/// - Leading glyph: a grey filled checkmark circle (done), an accent-tinted spinner (current), an accent
///   pause glyph (paused), a red danger icon (failed), an empty circle (upcoming).
/// - Title: same weight in every status; purple when `.current`/`.paused`, red when `.failed`, `TextHint`
///   grey when `.done`/`.upcoming` (no strikethrough).
/// - Value: the discovery tally ("N found"), a download/apply percentage, or nothing (the leading spinner
///   already conveys the refresh pass). Finished download/apply rows force 100%. Trails the title on the
///   same row, two points smaller so it reads as secondary.
/// - The active step (`.current`/`.paused`) gets a lavender progress-fill row highlight.
struct FullResyncStepRowView: View {
    let step: FullResyncStep

    /// The current and paused rows are the step the resync is sitting on: highlighted and accent-colored.
    private var isActive: Bool {
        step.status == .current || step.status == .paused
    }

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 20, height: 20)

            Text(step.title)
                .font(.system(size: 13))
                .foregroundStyle(titleColor)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let valueText {
                Text(valueText)
                    .font(.system(size: 11))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Localization.full_resync_step_label(number: step.number, title: step.title))
        .accessibilityValue(valueText ?? "")
    }

    // MARK: - Leading status glyph

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .done:
            // IconProvider icons carry a small internal margin, so they render a touch smaller than the
            // frame — sized to 16 to match the other glyphs (and the filled .failed icon).
            IconProvider.checkmarkCircleFilled
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(ColorProvider.TextHint)
        case .current:
            // Diameter 13 + the 2pt stroke draws at 15pt — a touch smaller reads better balanced against
            // the filled glyphs.
            SpinningProgressView(
                progress: 0,
                isIndeterminate: true,
                tint: ColorProvider.InteractionNorm,
                diameter: 13
            )
            .frame(width: 15, height: 15)
        case .paused:
            // The pause bars leave their box mostly empty, so they need more size than the
            // circular glyphs to read the same.
            IconProvider.pause
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundStyle(ColorProvider.InteractionNorm)
        case .failed:
            // Sized to 16 to compensate for the icon's internal margin (matches .done).
            IconProvider.exclamationCircleFilled
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(ColorProvider.SignalDanger)
        case .upcoming:
            Image(systemName: "circle")
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundStyle(ColorProvider.TextHint)
        }
    }

    private var titleColor: Color {
        switch step.status {
        case .current, .paused: ColorProvider.InteractionNorm
        case .done, .upcoming: ColorProvider.TextHint
        case .failed: ColorProvider.SignalDanger
        }
    }

    /// Lavender highlight for the active step, drawn as a left-anchored progress fill: determinate steps
    /// fill to their percentage, indeterminate/paused steps fill fully. Alpha is applied with SwiftUI
    /// `Color.opacity` (adaptive Color subscript, not NSColor.withAlphaComponent) so the tint follows the
    /// view's `colorScheme` in both light and dark mode.
    @ViewBuilder
    private var rowBackground: some View {
        if isActive {
            GeometryReader { geometry in
                ColorProvider.InteractionNorm.opacity(0.1)
                    .frame(width: geometry.size.width * progressFraction)
                    .animation(.easeInOut(duration: 0.3), value: progressFraction)
            }
        } else {
            Color.clear
        }
    }

    /// Fraction (0…1) of the row covered by the highlight. Determinate steps use their percentage;
    /// indeterminate current steps and paused rows fill fully.
    private var progressFraction: CGFloat {
        switch step.status {
        case .current, .paused:
            if case let .determinate(x, y) = step.detail {
                return CGFloat(Self.resyncPercent(x: x, y: y)) / 100
            }
            return 1
        case .done, .upcoming, .failed:
            return 0
        }
    }

    // MARK: - Trailing value

    /// The right-aligned value text, or nil when the row shows none (upcoming, failed, and the refresh pass).
    /// Single source of truth for both the visible value and the VoiceOver value.
    private var valueText: String? { Self.valueText(for: step) }

    /// Pure mapping of a step to its trailing value, so it is unit-testable.
    static func valueText(for step: FullResyncStep) -> String? {
        switch step.status {
        case .upcoming, .failed:
            return nil
        case .done:
            switch step.kind {
            case .discovering:
                guard let count = discoveredCount(from: step.detail) else { return nil }
                return Localization.full_resync_items_found(count: count.formatted(.number))
            case .downloading:
                // v2 downloads against a known total, so a finished pass reads 100%; a v1 download that
                // stayed indeterminate (no total) keeps its final "N found", matching its active display.
                if case .indeterminate(let count) = step.detail {
                    return Localization.full_resync_items_found(count: count.formatted(.number))
                }
                return Localization.full_resync_percent(percent: 100)
            case .applyingUpdates:
                return Localization.full_resync_percent(percent: 100)
            case .refreshingDetails:
                return nil
            }
        case .current, .paused:
            switch step.detail {
            case let .indeterminate(count):
                // Discovery (v2) and the pre-total download (v1) show a live "N found"; other indeterminate
                // phases show none (the spinner leads).
                guard step.kind == .discovering || step.kind == .downloading else { return nil }
                return Localization.full_resync_items_found(count: count.formatted(.number))
            case let .determinate(x, y):
                return Localization.full_resync_percent(percent: resyncPercent(x: x, y: y))
            case .spinnerOrCount, .none:
                return nil
            }
        }
    }

    private var valueColor: Color {
        switch step.status {
        case .current, .paused: ColorProvider.InteractionNorm
        case .done, .upcoming, .failed: ColorProvider.TextHint
        }
    }

    /// The count carried by a step's detail, for its "N found" tally.
    static func discoveredCount(from detail: FullResyncStep.StepDetail?) -> Int? {
        switch detail {
        case let .indeterminate(count): count
        case let .determinate(x, _): x
        case let .spinnerOrCount(processed): processed
        case nil: nil
        }
    }

    // MARK: - Percentage

    /// Progress percentage for a determinate step, rounded and clamped to 0…100. `y <= 0` yields 0.
    static func resyncPercent(x: Int, y: Int) -> Int {
        guard y > 0 else { return 0 }
        let percent = Int((Double(x) / Double(y) * 100).rounded())
        return min(max(percent, 0), 100)
    }
}

#if DEBUG
struct FullResyncStepRowView_Previews: PreviewProvider {
    private typealias State = ApplicationState.FullResyncState

    private static let scenarios: [(String, ApplicationState.FullResyncVariant, State, Int)] = [
        ("V2 · discovering (screen 2)", .v2, .inProgress(saved: 53033, total: nil), 0),
        ("V2 · downloading (screen 6)", .v2, .inProgress(saved: 30, total: 96), 1),
        ("V2 · applying updates (screen 7)", .v2, .enumerating(.waitingForTheWorkingSetEnumerationToFinish(seconds: 5, enumerated: 30, total: 100)), 2),
        ("V2 · refreshing (screen 9)", .v2, .enumerating(.fetchItemPassInProgress(seconds: 3, fetched: 40, expected: 100)), 3),
        ("V2 · paused on discovery", .v2, .paused(53033), 0),
        ("V2 · errored on discovery", .v2, .errored("Network connection lost"), 0),
        ("V1 · downloading (indeterminate, N found)", .v1, .inProgress(saved: 1200, total: nil), 0),
        ("V1 · applying updates", .v1, .enumerating(.waitingForTheWorkingSetEnumerationToFinish(seconds: 5, enumerated: 30, total: 100)), 1),
    ]

    static var previews: some View {
        Group {
            gallery
                .preferredColorScheme(.light)
                .previewDisplayName("Light")
            gallery
                .preferredColorScheme(.dark)
                .previewDisplayName("Dark")
        }
    }

    private static var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(scenarios, id: \.0) { label, variant, state, furthest in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(label)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(ColorProvider.TextWeak)
                        container(steps(variant: variant, state: state, furthest: furthest))
                    }
                }
            }
            .padding()
            .frame(width: 320)
        }
        .frame(width: 320, height: 820)
        .background(ColorProvider.BackgroundNorm)
    }

    /// Mirrors `ApplicationState`'s detail retention so finished rows show their final tally.
    private static func steps(variant: ApplicationState.FullResyncVariant, state: State, furthest: Int) -> [FullResyncStep] {
        var retained: [FullResyncStepKind: FullResyncStep.StepDetail] = [
            .downloading: .determinate(x: 96, y: 96),
            .applyingUpdates: .determinate(x: 100, y: 100)
        ]
        if variant == .v2 { retained[.discovering] = .indeterminate(count: 53033) }
        return FullResyncStepList.steps(variant: variant, state: state, furthestStep: furthest, stepDetails: retained)
    }

    private static func container(_ steps: [FullResyncStep]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 { Divider() }
                FullResyncStepRowView(step: step)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ColorProvider.BorderWeak, lineWidth: 1)
        )
    }
}
#endif
