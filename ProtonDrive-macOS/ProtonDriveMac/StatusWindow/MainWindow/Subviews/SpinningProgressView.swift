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
    private let progress: Int
    
    /// If true, the progress indicator keeps spinning. Otherwise it goes from 0 to 100%.
    private let isIndeterminate: Bool 
    
    init(
        progress: Int,
        isIndeterminate: Bool = false
    ) {
        self.progress = progress
        self.isIndeterminate = isIndeterminate
    }
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: 2)
                .foregroundColor(ColorProvider.TextHint.opacity(0.5))
                .frame(width: 12, height: 12)
            
            Circle()
                .trim(from: 0.0, to: fraction)
                .stroke(lineWidth: 2)
                .foregroundColor(ColorProvider.TextNorm)
                .frame(width: 12, height: 12)
                .rotationEffect(Angle(degrees: rotation))
        }
    }
    
    private var rotation: Double {
        if isIndeterminate {
            return Double(progress) / 100 * 360
        }
        return 270
    }
    
    /// Fraction of a circle displayed.
    private var fraction: Double {
        if isIndeterminate {
            // The spinning arc is a quarter-circle.
            0.25
        } else {
            // The arc goes from empty to full.
            Double(progress) / 100
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
        }
        .frame(width: 200, height: 200)
    }
}
