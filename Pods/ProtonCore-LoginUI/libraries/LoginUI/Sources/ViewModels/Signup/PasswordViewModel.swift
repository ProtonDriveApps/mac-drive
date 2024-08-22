//
//  PasswordViewModel.swift
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
import ProtonCoreLogin
import UIKit

class PasswordViewModel {

    func passwordValidationResult(for restrictions: SignupPasswordRestrictions,
                                  password: String,
                                  repeatParrword: String) -> (Result<(), SignupError>) {

        let passwordFailedRestrictions = restrictions.failedRestrictions(for: password)
        let repeatPasswordFailedRestrictions = restrictions.failedRestrictions(for: repeatParrword)

        if passwordFailedRestrictions.contains(.notEmpty) && repeatPasswordFailedRestrictions.contains(.notEmpty) {
            return .failure(SignupError.passwordEmpty)
        }

        // inform the user
        if passwordFailedRestrictions.contains(.atLeastEightCharactersLong)
            && repeatPasswordFailedRestrictions.contains(.notEmpty) {
            return .failure(SignupError.passwordShouldHaveAtLeastEightCharacters)
        }

        guard password == repeatParrword else {
            return .failure(SignupError.passwordNotEqual)
        }

        if passwordFailedRestrictions.contains(.atLeastEightCharactersLong)
            && repeatPasswordFailedRestrictions.contains(.atLeastEightCharactersLong) {
            return .failure(SignupError.passwordShouldHaveAtLeastEightCharacters)
        }

        return .success
    }

    func termsAttributedString(textView: UITextView) -> NSAttributedString {
        /// Fix me poissble bug: if _login_recovery_t_c_desc translated string doesnt match in _login_recovery_t_c_link translated string. the hyper link could be failed when clicking.
        var text = LUITranslation.recovery_t_c_desc.l10n
        let linkText = LUITranslation.recovery_t_c_link.l10n
        if ProcessInfo.processInfo.arguments.contains("RunningInUITests") {
            // Workaround for UI test automation to detect link in separated line
            let texts = text.components(separatedBy: linkText)
            if texts.count >= 2 {
                text = texts[0] + "\n" + linkText + texts[1]
            }
        }

        return .hyperlink(in: text, as: linkText, path: "", subfont: textView.font)
    }
}

#endif
