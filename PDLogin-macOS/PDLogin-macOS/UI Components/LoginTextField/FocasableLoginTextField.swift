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

struct FocasableLoginTextField<Content>: View where Content: View {
    private let action: () -> Void
    private let content: Content

    @FocusState private var isFocused: Bool
    private let unfocus: Bool

    @Binding private var errorString: String?
    @StateObject private var windowDelegate: TextFieldWindowListener

    init(errorString: Binding<String?>, unfocus: Bool, window: NSWindow, action: @escaping () -> Void, content: Content) {
        self._errorString = errorString
        self.action = action
        self.unfocus = unfocus

        self.content = content

        self._windowDelegate = StateObject(wrappedValue: TextFieldWindowListener(window: window))
    }

    var body: some View {
        // Allows externally-determined factors to remove focus (e.g. loading)
        if unfocus && isFocused {
            self.isFocused = false
        }

        return content
            .onSubmit(action)
            .focused($isFocused)
            .onChange(of: isFocused) { windowDelegate.isFocused = $0 }
            .onChange(of: windowDelegate.isFocused) { isFocused = $0 }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(hightlightColor, lineWidth: 4)
                    .padding(-3) // draw outside the textfield's dimensions
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
    }

    private var borderColor: Color {
        if isFocused {
            return ColorProvider.InteractionNorm
        } else {
            if errorString != nil {
                return ColorProvider.SignalDanger
            } else {
                return ColorProvider.FieldNorm
            }
        }
    }

    private var hightlightColor: Color {
        return isFocused ? ColorProvider.FieldHighlight : .clear
    }
}

private final class TextFieldWindowListener: ObservableObject {
    private var wasFocused = false
    @Published var isFocused: Bool = false

    init(window: NSWindow) {
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
    }

    @objc func windowDidResignKey() {
        wasFocused = isFocused
        isFocused = false
    }

    @objc func windowDidBecomeKey() {
        if wasFocused {
            isFocused = true
        }
    }
}
