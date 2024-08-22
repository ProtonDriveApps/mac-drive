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

public struct LoginButton: View {
    private let title: String
    private let action: () -> Void

    @Binding var isLoading: Bool
    
    public init(title: String,
                isLoading: Binding<Bool>,
                action: @escaping () -> Void) {
        self.title = title
        self._isLoading = isLoading
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            ZStack {
                Text(title)
                    .font(.system(size: 13))
                    .fontWeight(.semibold)
                    .foregroundColor(ColorProvider.TextInvert)
                    .padding(.horizontal)
                    .frame(maxWidth: 400)
                    .frame(height: 44, alignment: .center)

                if isLoading {
                    HStack {
                        Spacer()

                        ProgressView()
                            .progressViewStyle(.circular)
                            .colorInvert()
                            .brightness(0.6) // unfortunate hack since setting a tint color doesn't work on macOS
                            .scaleEffect(0.55)
                            .frame(alignment: .trailing)
                            .padding(.trailing, 11)
                    }
                }
            }
        }
        .buttonStyle(LoginButtonStyle())
        .disabled(isLoading)
    }
}

private struct LoginButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LoginButtonStyleView(configuration: configuration)
    }
}

private struct LoginButtonStyleView: View {
    @Environment(\.isEnabled) var isEnabled

    @State private var isHovering = false

    let configuration: LoginButtonStyle.Configuration

    var body: some View {
        configuration.label
            .background(backgroundColor)
            .cornerRadius(8)
            .onHover {
                isHovering = $0
            }
    }

    private var backgroundColor: Color {
        if configuration.isPressed {
            return ColorProvider.InteractionNormActive
        } else if isHovering {
            return ColorProvider.InteractionNormHover
        } else if isEnabled {
            return ColorProvider.InteractionNorm
        } else {
            return ColorProvider.InteractionNormHover
        }
    }
}

struct LoginButton_Previews: PreviewProvider {
    static var previews: some View {
        LoginButton(title: "Start", isLoading: .constant(false), action: { })
            .previewLayout(.sizeThatFits)
    }
}
