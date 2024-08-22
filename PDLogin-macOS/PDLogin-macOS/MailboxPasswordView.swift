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

struct MailboxPasswordView: View {
    @ObservedObject private var vm: MailboxPasswordViewModel
    private let window: NSWindow

    init(vm: MailboxPasswordViewModel, window: NSWindow) {
        self.vm = vm
        self.window = window
    }

    var body: some View {
        VStack(spacing: 0) {
            Image("login_logo", bundle: PDLoginMacOS.bundle)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 188, height: 36)
                .padding(.top, 24)
                .padding(.bottom, 30)

            Text("Unlock your mailbox")
                .foregroundColor(ColorProvider.TextNorm)
                .font(.system(size: 17))
                .fontWeight(.semibold)

            VStack(spacing: 8) {
                SecureLoginTextField(title: "Mailbox password", text: $vm.password, errorString: $vm.passwordValidationFailureMessage, unfocus: vm.isLoading, window: window, action: vm.unlock)
                    .accessibilityIdentifier("MailboxPasswordView.TextField.password")

                VStack(spacing: 30) {
                    LoginButton(title: "Unlock", isLoading: $vm.isLoading, action: vm.unlock)
                        .accessibilityIdentifier("MailboxPasswordView.LoginButton.unlock")

                    LinkButton(title: "Forgot password", action: vm.forgotPassword)
                }
            }
            .padding(.top, 24)
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
