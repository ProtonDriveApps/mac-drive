// Copyright (c) 2024 Proton AG
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

struct SpinningProgressView: View {
    /// On a scale of 0 to 100.
    private let progress: Double

    /// If true, the progress indicator keeps spinning. Otherwise it goes from 0 to 100%.
    private let isIndeterminate: Bool

    /// When set, both circles use this colour: the arc at full strength, the track at reduced
    /// opacity. Nil keeps the neutral default.
    private let tint: Color?

    private let tintedTrackOpacity: Double = 0.2

    /// Diameter of the circle path. The 2pt stroke is centred on the path, so it extends 1pt beyond
    /// this on each side: pass `glyphSize - 2` to line the indicator up with an icon of `glyphSize`.
    private let diameter: CGFloat

    private let indeterminateRotationDuration: TimeInterval = 1

    init(
        progress: Double,
        isIndeterminate: Bool = false,
        tint: Color? = nil,
        diameter: CGFloat = 12
    ) {
        self.progress = progress
        self.isIndeterminate = isIndeterminate
        self.tint = tint
        self.diameter = diameter
    }
    
    var body: some View {
        if isIndeterminate {
            TimelineView(.animation) { context in
                indicator(rotation: indeterminateRotation(at: context.date), fraction: fraction)
            }
        } else {
            indicator(rotation: rotation, fraction: fraction)
        }
    }

    private func indicator(rotation: Double, fraction: Double) -> some View {
        ZStack {
            Circle()
                .stroke(lineWidth: 2)
                .foregroundColor(trackColor)
                .frame(width: diameter, height: diameter)

            Circle()
                .trim(from: 0.0, to: fraction)
                .stroke(lineWidth: 2)
                .foregroundColor(arcColor)
                .frame(width: diameter, height: diameter)
                .rotationEffect(Angle(degrees: rotation))
        }
    }

    private var trackColor: Color {
        guard let tint else { return ColorProvider.TextHint.opacity(0.5) }
        return tint.opacity(tintedTrackOpacity)
    }

    private var arcColor: Color {
        tint ?? ColorProvider.TextNorm
    }

    private func indeterminateRotation(at date: Date) -> Double {
        let progress = date
            .timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: indeterminateRotationDuration) / indeterminateRotationDuration
        return progress * 360.0
    }
    
    private var rotation: Double {
        return 270
    }
    
    /// Fraction of a circle displayed.
    private var fraction: Double {
        if isIndeterminate {
            // The spinning arc is a quarter-circle.
            0.25
        } else {
            // The arc goes from empty to full.
            progress / 100.0
        }
    }
}

struct SpinningProgressView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Spacer()
            SpinningProgressView(progress: 0)
            Spacer()
            SpinningProgressView(progress: 25)
            Spacer()
            SpinningProgressView(progress: 50)
            Spacer()
            SpinningProgressView(progress: 75)
            Spacer()
            SpinningProgressView(progress: 100)
            Spacer()
            SpinningProgressView(progress: 0, isIndeterminate: true)
            Spacer()
            SpinningProgressView(progress: 25, isIndeterminate: true)
            Spacer()
            SpinningProgressView(progress: 50, isIndeterminate: true)
            Spacer()
            SpinningProgressView(progress: 75, isIndeterminate: true)
            Spacer()
            SpinningProgressView(progress: 100, isIndeterminate: true)
            Spacer()
            SpinningProgressView(progress: 0, isIndeterminate: true, tint: ColorProvider.InteractionNorm)
            Spacer()
            // As drawn by the full resync step list.
            SpinningProgressView(progress: 0, isIndeterminate: true, tint: ColorProvider.InteractionNorm, diameter: 14)
            Spacer()
        }
        .frame(width: 200, height: 200)
    }
}
