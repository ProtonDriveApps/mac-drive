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

extension View {
    func configureLoginTextFieldBorder(errorString: Binding<String?>, unfocus: Bool, window: NSWindow, action: @escaping () -> Void) -> some View {
        ModifiedContent(content: self, modifier: CommonLoginTextFieldModifier(errorString: errorString, unfocus: unfocus, window: window, action: action))
    }
}

private struct CommonLoginTextFieldModifier: ViewModifier {
    private let unfocus: Bool
    private let window: NSWindow
    private let action: () -> Void

    @Binding private var errorString: String?

    init(errorString: Binding<String?>, unfocus: Bool, window: NSWindow, action: @escaping () -> Void) {
        self._errorString = errorString
        self.unfocus = unfocus
        self.window = window
        self.action = action
    }

    func body(content: Content) -> some View {
        FocasableLoginTextField(errorString: $errorString, unfocus: unfocus, window: window, action: action, content: content)
    }
}
