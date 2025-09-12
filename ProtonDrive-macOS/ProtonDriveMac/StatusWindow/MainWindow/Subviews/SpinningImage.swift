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

import SwiftUI

struct SpinningImage: View {
    @State private var spinning = false

    private let name: String
    private let duration: Double

    init(_ name: String, duration: Double = 1) {
        self.name = name
        self.duration = duration
    }

    var body: some View {
        Image(name)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(
                .linear(duration: duration)
                    .repeatForever(autoreverses: false),
                value: spinning
            )
            .onAppear {
                spinning = true
            }
    }
}
