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

/// Modifier to help config Text
public struct TextModifier: ViewModifier {
    let alignment: Alignment
    let fontSize: CGFloat
    let textColor: Color
    let maxWidth: CGFloat?
    
    public init(
        alignment: Alignment = .leading,
        fontSize: CGFloat = 15,
        textColor: Color = ColorProvider.TextWeak,
        maxWidth: CGFloat? = .infinity
    ) {
        self.alignment = alignment
        self.fontSize = fontSize
        self.textColor = textColor
        self.maxWidth = maxWidth
    }
    
    public func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth, alignment: alignment)
            .font(.system(size: fontSize))
            .foregroundStyle(textColor)
    }
}
