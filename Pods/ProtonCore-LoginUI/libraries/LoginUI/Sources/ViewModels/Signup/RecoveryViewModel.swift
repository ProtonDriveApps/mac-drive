//
//  RecoveryViewModel.swift
//  ProtonCore-Login - Created on 11/03/2021.
//
//  Copyright (c) 2022 Proton Technologies AG
//
//  This file is part of Proton Technologies AG and ProtonCore.
//
//  ProtonCore is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonCore is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonCore.  If not, see <https://www.gnu.org/licenses/>.

#if os(iOS)

import Foundation
import ProtonCoreChallenge
import ProtonCoreLogin

class RecoveryViewModel {

    private let signupService: Signup
    let initialCountryCode: Int
    let challenge: PMChallenge

    init(signupService: Signup, initialCountryCode: Int, challenge: PMChallenge) {
        self.signupService = signupService
        self.initialCountryCode = initialCountryCode
        self.challenge = challenge
    }

    func isValidEmail(email: String) -> Bool {
        guard !email.isEmpty else { return false }
        return email.isValidEmail()
    }

    func validateEmailServerSide(email: String, completion: @escaping (Result<Void, SignupError>) -> Void) {
        signupService.validateEmailServerSide(email: email, completion: completion)
    }

    func isValidPhoneNumber(number: String) -> Bool {
        return !number.isEmpty
    }

    func validatePhoneNumberServerSide(number: String, completion: @escaping (Result<Void, SignupError>) -> Void) {
        signupService.validatePhoneNumberServerSide(number: number, completion: completion)
    }

}

#endif
