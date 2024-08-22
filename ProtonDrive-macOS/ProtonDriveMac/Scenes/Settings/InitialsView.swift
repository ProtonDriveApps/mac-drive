// Copyright (c) 2023 Proton AG
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

struct InitialsView: View {
    private let initials: String

    init(_ initials: String) {
        self.initials = initials
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .frame(width: 32, height: 32)
                .foregroundColor(ColorProvider.InteractionNorm)

            Text(initials)
                .font(.system(size: 12))
                .foregroundColor(ColorProvider.TextInvert)
        }
    }
}

struct InitialsView_Previews: PreviewProvider {
    static var previews: some View {
        InitialsView("FL")
    }
}
