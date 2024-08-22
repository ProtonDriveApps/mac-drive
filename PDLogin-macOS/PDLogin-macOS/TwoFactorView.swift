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

struct TwoFactorView: View {
    @ObservedObject private var vm: TwoFactorViewModel
    private let window: NSWindow

    init(vm: TwoFactorViewModel, window: NSWindow) {
        self.vm = vm
        self.window = window
    }

    var body: some View {
        VStack {

            Image("login_logo", bundle: PDLoginMacOS.bundle)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 188, height: 36)
                .padding(.top, 24)
                .padding(.bottom, 16)

            VStack {
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

                LoginTextField(title: "", text: $vm.code, errorString: $vm.codeValidationFailureMessage, unfocus: vm.isLoading, window: window, action: vm.authenticate)
                    .accessibilityIdentifier("TwoFactorView.TextField.2FACode")

                VStack(spacing: 30) {
                    LoginButton(title: "Authenticate", isLoading: $vm.isLoading, action: vm.authenticate)
                        .accessibilityIdentifier("TwoFactorView.LoginButton.authenticate")

                    LinkButton(title: vm.changeModeTitle, action: vm.toggleMode)
                        .accessibilityIdentifier("TwoFactorView.LinkButton.changeMode")
                }
            }
            .frame(width: 300)

            Spacer()
        }
        .padding(.horizontal, 54)
        .background(ColorProvider.BackgroundNorm)
        .frame(width: 420)
        .frame(idealHeight: 480, maxHeight: .infinity)
        .errorToast(errors: vm.errors)
    }
}
