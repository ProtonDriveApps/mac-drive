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
import ProtonCoreLogin
import PDUIComponents
import AppKit

final class MailboxPasswordViewModel: ObservableObject {
    // MARK: - Properties

    @Published var finished: LoginStep?
    let errors = ErrorToastModifier.Stream()
    @Published var isLoading: Bool = false
    @Published var password = ""
    @Published var passwordValidationFailureMessage: String?

    private let login: Login

    init(login: Login) {
        self.login = login
    }

    // MARK: - Actions

    func unlock() {
        errors.send(nil)
        isLoading = true

        guard validate() else {
            DispatchQueue.main.async {
                self.isLoading = false
            }
            return
        }

        // we know that password mode is .two because we are in the MailboxPasswordViewModel, shown only when there's a second password needed
        login.finishLoginFlow(mailboxPassword: password, passwordMode: .two) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                switch result {
                case let .failure(error):
                    self?.errors.send(error)
                    self?.isLoading = false
                case let .success(status):
                    switch status {
                    case let .finished(data):
                        self?.finished = .done(data)
                    case .chooseInternalUsernameAndCreateInternalAddress:
                        fatalError("Account has a username but no address")
                    case .askAny2FA, .askTOTP, .askSecondPassword:
                        fatalError("Invalid state \(status) after entering Mailbox password")
                    case .ssoChallenge:
                        fatalError("receiving an SSO Challenge after entering Mailbox password is an invalid state")
                    case .askFIDO2:
                        assertionFailure("FIDO2 not implemented")
                        self?.errors.send(LoginError.invalidState)
                        self?.isLoading = false
                    @unknown default:
                        assertionFailure("Not implemented")
                        self?.errors.send(LoginError.invalidState)
                        self?.isLoading = false
                    }
                }
            }
        }
    }

    func forgotPassword() {
        NSWorkspace.shared.open(ExternalLinks.passwordReset)
    }

    func backToStart() {
        finished = .backToStart
    }

    // MARK: - Validation

    private func validate() -> Bool {
        passwordValidationFailureMessage = password.isEmpty ? "This field is required" : nil

        return passwordValidationFailureMessage == nil
    }
}
