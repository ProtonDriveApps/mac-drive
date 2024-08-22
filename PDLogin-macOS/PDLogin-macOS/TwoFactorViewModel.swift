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

final class TwoFactorViewModel: ObservableObject {
    enum Mode {
        case twoFactorCode
        case recoveryCode

        var toggle: Mode {
            switch self {
            case .twoFactorCode: return .recoveryCode
            case .recoveryCode: return .twoFactorCode
            }
        }
    }

    // MARK: - Properties

    @Published var finished: LoginStep?
    let errors = ErrorToastModifier.Stream()
    @Published var isLoading: Bool = false
    @Published var mode: Mode = .twoFactorCode
    @Published var code = ""
    @Published var codeValidationFailureMessage: String?

    private let login: Login

    var title: String {
        "Two-factor authentication"
    }

    var subtitle: String {
        mode == .twoFactorCode ? "Enter the code from your authenticator app" : "Enter the recovery code"
    }

    var changeModeTitle: String {
        mode == .twoFactorCode ? "Use recovery code" : "Use two-factor code"
    }

    init(login: Login) {
        self.login = login
    }

    // MARK: - Actions

    func authenticate() {
        errors.send(nil)
        isLoading = true

        guard validate() else {
            DispatchQueue.main.async {
                self.isLoading = false
            }
            return
        }

        login.provide2FACode(code) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                switch result {
                case let .failure(error):
                    self?.errors.send(error)
                    self?.isLoading = false
                case let .success(status):
                    switch status {
                    case let .finished(data):
                        self?.finished = .done(data)
                    case .askSecondPassword:
                        self?.finished = .mailboxPasswordNeeded
                        self?.isLoading = false
                    case .chooseInternalUsernameAndCreateInternalAddress:
                        fatalError("Account has a username but no address")
                    case .askTOTP, .askAny2FA:
                        fatalError("Asking for 2FA code password after successful 2FA code is an invalid state")
                    case .ssoChallenge:
                        fatalError("receiving an SSO Challenge after successful 2FA code is an invalid state")
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

    func toggleMode() {
        mode = mode.toggle
    }

    func backToStart() {
        finished = .backToStart
    }

    // MARK: - Validation

    private func validate() -> Bool {
        codeValidationFailureMessage = code.isEmpty ? "This field is required" : nil

        return codeValidationFailureMessage == nil
    }
}
