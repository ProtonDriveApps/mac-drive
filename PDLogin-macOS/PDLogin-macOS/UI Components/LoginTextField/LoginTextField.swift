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

import Foundation
import SwiftUI
import ProtonCoreUIFoundations
import PDUIComponents

struct LoginTextField: View {
    private let title: String
    private let textContentType: NSTextContentType?
    private let unfocus: Bool
    private let window: NSWindow
    private let action: () -> Void

    @Binding private var text: String
    @Binding private var errorString: String?

    init(title: String, text: Binding<String>, errorString: Binding<String?>,
         textContentType: NSTextContentType? = nil, unfocus: Bool, window: NSWindow, action: @escaping () -> Void = {}) {
        self.title = title
        self._text = text
        self._errorString = errorString
        self.unfocus = unfocus
        self.textContentType = textContentType
        self.window = window
        self.action = action
    }

    var body: some View {
        CommonLoginTextField(title: title, text: $text, errorString: $errorString, unfocus: unfocus, window: window, action: action, content:
            TextField("", text: $text)
                .textContentType(textContentType)
        )
    }
}

struct SecureLoginTextField: View {
    private let title: String
    private let unfocus: Bool
    private let window: NSWindow
    private let action: () -> Void

    @Binding private var text: String
    @Binding private var errorString: String?
    @State private var isSecure: Bool = true

    init(title: String, text: Binding<String>, errorString: Binding<String?>, unfocus: Bool, window: NSWindow, action: @escaping () -> Void = {}) {
        self.title = title
        self._text = text
        self._errorString = errorString
        self.unfocus = unfocus
        self.window = window
        self.action = action
    }

    var body: some View {
        CommonLoginTextField(title: title, text: $text, errorString: $errorString, unfocus: unfocus, window: window, action: action, content:
            HStack {
                textField

                Button(action: {
                    isSecure.toggle()
                }, label: {
                    textFieldIcon
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16)
                })
                    .buttonStyle(.plain)
            }
        )
    }

    @ViewBuilder
    private var textField: some View {
        if isSecure {
            SecureField("", text: $text)
                .textContentType(.password)
        } else {
            TextField("", text: $text)
        }
    }

    private var textFieldIcon: Image {
        isSecure ? IconProvider.eye : IconProvider.eyeSlash
    }
}

private struct CommonLoginTextField<Content>: View where Content: View {
    private let title: String
    private let unfocus: Bool
    private let window: NSWindow
    private let content: Content
    private let action: () -> Void

    @Binding private var text: String
    @Binding private var errorString: String?

    init(title: String, text: Binding<String>, errorString: Binding<String?>, unfocus: Bool, window: NSWindow, action: @escaping () -> Void, content: Content) {
        self.title = title
        self.unfocus = unfocus
        self.window = window
        self.action = action
        self._text = text
        self._errorString = errorString
        self.content = content
    }

    var body: some View {
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12))

            content
                .textFieldStyle(.plain)
                .disableAutocorrection(true)
                .font(.system(size: 14))
                .padding(.horizontal, 13)
                .foregroundColor(ColorProvider.TextNorm)
                .frame(minHeight: 36)
                .cornerRadius(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .foregroundColor(ColorProvider.BackgroundNorm)
                )
                .configureLoginTextFieldBorder(errorString: $errorString, unfocus: unfocus, window: window, action: action)
                .onChange(of: text) { _ in
                    errorString = nil
                }

            textFieldLegend
        }
    }

    @ViewBuilder
    private var textFieldLegend: some View {
        Group {
            HStack(alignment: .center, spacing: 5) {
                if let errorString = errorString {
                    WarningBadgeView()
                        .frame(width: 14, height: 14)
                    Text(errorString)
                        .font(.system(size: 12))
                        .fontWeight(.semibold)
                        .foregroundColor(ColorProvider.SignalDanger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Rectangle()
                        .foregroundColor(.clear)
                }
            }
            .frame(height: 14)
        }
        .font(.caption)
    }
}
