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

struct TwoFAWithOneTimeCodeView: View {
    @ObservedObject private var vm: TwoFAWithOneTimeCodeViewModel
    private let window: NSWindow
    var isNested: Bool = false

    init(vm: TwoFAWithOneTimeCodeViewModel, isNested: Bool = false, window: NSWindow) {
        self.vm = vm
        self.window = window
        self.isNested = isNested
    }

    var body: some View {
        VStack {

            if !isNested {
                PDLoginMacOS.logoImage
                    .padding(.bottom, 16)
            }

            VStack {
                if isNested {
                    Text(vm.subtitle)
                        .foregroundColor(ColorProvider.TextNorm)
                        .font(.system(size: 12))
                        .fontWeight(.light)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                } else {
                    VStack(spacing: 8) {
                        Text(vm.title)
                            .foregroundColor(ColorProvider.TextNorm)
                            .font(.system(size: 17))
                            .fontWeight(.semibold)
                        
                        Text(vm.subtitle)
                            .foregroundColor(ColorProvider.TextNorm)
                            .font(.system(size: 12))
                            .fontWeight(.light)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.center)
                    }
                    .padding(4)
                }

                LoginTextField(title: "", text: $vm.code, errorString: $vm.codeValidationFailureMessage, isLoading: vm.isLoading, window: window, action: vm.authenticate)
                    .accessibilityIdentifier("TwoFAWithOneTimeCodeView.TextField.2FACode")

                VStack(spacing: 30) {
                    LoginButton(title: "Authenticate", isLoading: $vm.isLoading, action: vm.authenticate)
                        .accessibilityIdentifier("TwoFAWithOneTimeCodeView.LoginButton.authenticate")

                    LinkButton(title: vm.changeModeTitle, action: vm.toggleMode)
                        .accessibilityIdentifier("TwoFAWithOneTimeCodeView.LinkButton.changeMode")
                }
            }
            .frame(width: PDLoginMacOS.contentWidth)

            Spacer()
        }
        .padding(.horizontal, PDLoginMacOS.contentHorizontalPadding)
        .background(ColorProvider.BackgroundNorm)
        .frame(width: PDLoginMacOS.frameWidth)
        .frame(idealHeight: PDLoginMacOS.frameHeight, maxHeight: .infinity)
        .if(!isNested) { $0.errorToast(errors: vm.errors) }
        
    }
}
