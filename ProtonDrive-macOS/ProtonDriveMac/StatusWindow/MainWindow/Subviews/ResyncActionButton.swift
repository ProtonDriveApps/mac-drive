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

/// A resync action button: an optional leading icon + title, in a primary (accent-filled) or secondary
/// (bordered) style. 44pt tall, 8pt corner radius, and fills the width offered to it (so a side-by-side
/// pair splits evenly and a lone button spans full width).
///
/// Titles wrap to two lines, which is what lets a pair share one row at this window width; a long
/// localization that still does not fit scales down rather than truncating.
struct ResyncActionButton: View {
    enum Style {
        case primary
        case secondary
    }

    private let title: String
    private let icon: Image?
    private let style: Style
    private let action: () -> Void

    init(title: String, icon: Image? = nil, style: Style, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    icon
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
            }
            // The inset keeps a wrapped title off the button edges; the height holds two 13pt lines.
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
        .buttonStyle(ResyncActionButtonStyle(style: style))
    }
}

private struct ResyncActionButtonStyle: ButtonStyle {
    let style: ResyncActionButton.Style

    func makeBody(configuration: Configuration) -> some View {
        ResyncActionButtonStyleBody(style: style, configuration: configuration)
    }
}

private struct ResyncActionButtonStyleBody: View {
    @State private var isHovering = false
    let style: ResyncActionButton.Style
    let configuration: ButtonStyle.Configuration

    var body: some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(border)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }

    private var foreground: Color {
        switch style {
        case .primary: ColorProvider.White
        case .secondary: ColorProvider.TextNorm
        }
    }

    // Alpha is applied via SwiftUI `Color.opacity` (adaptive Color subscript), not NSColor.withAlphaComponent,
    // so the fill follows the view's color scheme in both light and dark mode.
    private var background: Color {
        switch style {
        case .primary:
            if configuration.isPressed {
                ColorProvider.InteractionNormActive
            } else if isHovering {
                ColorProvider.InteractionNormHover
            } else {
                ColorProvider.InteractionNorm
            }
        case .secondary:
            if configuration.isPressed {
                ColorProvider.InteractionWeakActive
            } else if isHovering {
                ColorProvider.InteractionWeakHover
            } else {
                ColorProvider.InteractionWeak
            }
        }
    }

    @ViewBuilder
    private var border: some View {
        if style == .secondary {
            RoundedRectangle(cornerRadius: 8)
                .stroke(ColorProvider.BorderNorm, lineWidth: 1)
        }
    }
}

#if DEBUG
struct ResyncActionButton_Previews: PreviewProvider {
    private static var gallery: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ResyncActionButton(title: "Cancel", icon: IconProvider.crossCircle, style: .secondary, action: {})
                ResyncActionButton(title: "Pause", icon: IconProvider.pause, style: .primary, action: {})
            }
            HStack(spacing: 12) {
                ResyncActionButton(title: "Cancel", icon: IconProvider.crossCircle, style: .secondary, action: {})
                ResyncActionButton(title: "Resume", icon: IconProvider.play, style: .primary, action: {})
            }
            HStack(spacing: 12) {
                ResyncActionButton(title: "Cancel", icon: IconProvider.crossCircle, style: .secondary, action: {})
                ResyncActionButton(title: "Retry", icon: IconProvider.arrowsRotate, style: .primary, action: {})
            }
        }
        .padding()
        .frame(width: 320)
        .background(ColorProvider.BackgroundNorm)
    }

    static var previews: some View {
        Group {
            gallery.preferredColorScheme(.light).previewDisplayName("Light")
            gallery.preferredColorScheme(.dark).previewDisplayName("Dark")
        }
    }
}
#endif
