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

import AppKit
import Foundation
import ProtonCoreLogin
import ProtonCoreEnvironment
import PDUIComponents

final class LoginViewModel: ObservableObject {
    // MARK: - Properties

    @Published var finished: LoginStep?
    let errors = ErrorToastModifier.Stream()
    @Published var isLoading: Bool = false
    @Published var username = ""
    @Published var password = ""
    @Published var usernameValidationFailureMessage: String?
    @Published var passwordValidationFailureMessage: String?
    @Published var loginButtonTitle: String = "Sign in"
    var usernameFieldLabel: String {
        if self.domain.hasSuffix(Environment.driveProd.doh.signupDomain) {
            "Email or username"
        } else {
            "Email or username (\(self.domain))"
        }
    }

    private let login: Login
    private let domain: String
    
    init(login: Login, domain: String) {
        self.login = login
        self.domain = domain

        subscribeToLoadingStatus()
    }

    // MARK: - Actions

    func logIn() {
        errors.send(nil)
        isLoading = true

        guard validate() else {
            DispatchQueue.main.async {
                self.isLoading = false
            }
            return	
        }
        
        let username = username
        let password = password
        login.login(username: username, password: password, intent: nil, challenge: nil) { [weak self] result in
            Task { @MainActor [weak self] in
                switch result {
                case let .failure(error):
                    self?.errors.send(error)
                    self?.isLoading = false
                case let .success(status):
                    switch status {
                    case let .finished(data):
                        self?.finished = .done(data)
                    case .askAny2FA, .askTOTP:
                        self?.finished = .twoFactorCodeNeeded
                        self?.isLoading = false
                    case .askSecondPassword:
                        self?.finished = .mailboxPasswordNeeded
                        self?.isLoading = false
                    case .chooseInternalUsernameAndCreateInternalAddress:
                        fatalError("Account has a username but no address")
                    case .ssoChallenge:
                        fatalError("receiving an SSO Challenge here is an invalid state")
                    case .askFIDO2:
                        assertionFailure("FIDO2 not implemented")
                        self?.errors.send(LoginError.invalidState)
                        self?.isLoading = false
                    }
                }
            }
        }
    }

    func subscribeToLoadingStatus() {
        $isLoading
            .map { $0 ? "Signing in..." : "Sign in" }
            .assign(to: &$loginButtonTitle)
    }

    func showHelp() {
        NSWorkspace.shared.open(ExternalLinks.commonLoginProblems)
    }

    func createOrUpgradeAccount() {
        NSWorkspace.shared.open(ExternalLinks.accountSetup)
    }

    // MARK: - Validation

    private func validate() -> Bool {
        usernameValidationFailureMessage = username.isEmpty ? "This field is required" : nil
        passwordValidationFailureMessage = password.isEmpty ? "This field is required" : nil

        return usernameValidationFailureMessage == nil && passwordValidationFailureMessage == nil
    }
}
