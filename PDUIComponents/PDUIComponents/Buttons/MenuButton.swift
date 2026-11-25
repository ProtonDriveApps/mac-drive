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

public struct MenuButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: {
            action()
        }, label: {
            IconProvider.hamburger
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(Color.IconNorm)
        })
        // On iOS 26 the toolbar puts the icon in a 44pt Liquid Glass circle, and a 40pt frame on top of that
        // stretches it wider than tall. Matches MenuNavigationViewController's UIKit button.
        .frame(width: usesGlassToolbar ? nil : 40, height: usesGlassToolbar ? nil : 40)
        .accessibility(identifier: "Button.BurgerMenu")
    }

    private var usesGlassToolbar: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return true
        }
        #endif
        return false
    }
}

public struct BackButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: {
            action()
        }, label: {
            IconProvider.arrowLeft
                .resizable()
                .frame(width: 24, height: 24)
                .foregroundColor(Color.IconNorm)
        })
        .frame(width: 40, height: 40)
        .accessibility(identifier: "Button.BackButton")
    }
}
