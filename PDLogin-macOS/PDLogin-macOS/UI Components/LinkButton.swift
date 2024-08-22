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

public struct LinkButton: View {
    private let title: String
    private let action: () -> Void
    
    public init(title: String,
                action: @escaping () -> Void)
    {
        self.title = title
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .fontWeight(.semibold)
        }
        .multilineTextAlignment(.center)
        .buttonStyle(LightButtonStyle())
    }
}

private struct LightButtonStyle: ButtonStyle {
    func makeBody(configuration: Self.Configuration) -> some View {
        LightButtonStyleView(configuration: configuration)
    }
}

private struct LightButtonStyleView: View {
    let configuration: LightButtonStyle.Configuration

    var body: some View {
        configuration.label
            .foregroundColor(color)
    }

    private var color: Color {
        return configuration.isPressed ? ColorProvider.InteractionNormActive : ColorProvider.InteractionNorm
    }
}

struct LightButton_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LinkButton(title: "Need help?", action: { })
                .background(ColorProvider.BackgroundNorm)
                .colorScheme(.light)
            
            LinkButton(title: "Need help?", action: { })
                .background(ColorProvider.BackgroundNorm)
                .colorScheme(.dark)
        }
        .previewLayout(.sizeThatFits)
    }
}
