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

public struct SimpleCloseButtonView: View {
    private var dismiss: () -> Void
    private let applyGlassStyle: Bool

    public init(applyGlassStyle: Bool = true, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        self.applyGlassStyle = applyGlassStyle
    }
    
    public var body: some View {
        #if os(iOS)
        if applyGlassStyle {
            content
                .modifier(GlassStyleModifier())
        } else {
            content
        }
        #else
        content
        #endif
    }

    private var content: some View {
        Button(action: self.dismiss) {
            IconProvider.cross
                .resizable()
                .frame(width: 24, height: 24, alignment: .center)
                .foregroundColor(Color.IconNorm)
        }
        .frame(width: 48, height: 48, alignment: .center)
        .accessibility(identifier: "SimpleCloseButtonView.Button.Close")
    }
}
