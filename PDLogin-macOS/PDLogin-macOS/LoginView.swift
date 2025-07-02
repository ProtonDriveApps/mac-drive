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
import ProtonCoreLogin

struct LoginView: View {
    @ObservedObject private var vm: LoginViewModel
    private let initialError: LoginError?
    private let window: NSWindow

    init(vm: LoginViewModel, initialError: LoginError? = nil, window: NSWindow) {
        self.vm = vm
        self.initialError = initialError
        self.window = window
    }

    var body: some View {

        VStack(spacing: 60) {

            Image("login_logo", bundle: PDLoginMacOS.bundle)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 188, height: 36)
                .padding(.top, 24)

            VStack(spacing: 0) {
                LoginTextField(title: vm.usernameFieldLabel, text: $vm.username, errorString: $vm.usernameValidationFailureMessage, textContentType: .username, unfocus: vm.isLoading, window: window)
                    .accessibility(identifier: "LoginView.TextField.username")

                SecureLoginTextField(title: "Password", text: $vm.password, errorString: $vm.passwordValidationFailureMessage, unfocus: vm.isLoading, window: window, action: vm.logIn)
                    .accessibility(identifier: "LoginView.TextField.password")

                LoginButton(title: vm.loginButtonTitle, isLoading: $vm.isLoading, action: vm.logIn)
                    .padding(.top, 8)
                    .accessibility(identifier: "LoginView.LoginButton.signIn")
            }
            .frame(width: 300)

            HStack {
                LinkButton(title: "Create account", action: vm.createOrUpgradeAccount)
                Spacer()
                LinkButton(title: "Help", action: vm.showHelp)
            }
            .padding(. horizontal, 4)
        }
        .padding(.horizontal, 54)
        .padding(.bottom, 52)
        .background(ColorProvider.BackgroundNorm)
        .frame(width: 420)
        .frame(idealHeight: 480, maxHeight: .infinity)
        .errorToast(errors: vm.errors)
        .onAppear {
            if let initialError {
                vm.errors.send(initialError)
            }
        }
    }
}
