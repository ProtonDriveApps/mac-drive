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
import ProtonCoreLoginUI

extension LoginError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSecondPassword:
            return LUITranslation.error_invalid_mailbox_password.l10n
        case .invalidCredentials(let message):
            return message
        case .invalid2FACode(let message):
            return message
        case .invalidAccessToken(let message):
            return message
        case .initialError(let message):
            return message
        case .generic(let message, _, _):
            return message
        case .apiMightBeBlocked(let message, _):
            return message
        case .externalAccountsNotSupported(let message, _, _):
            return message
        case .invalidState:
            return LSTranslation._loginservice_error_generic.l10n
        case .missingKeys:
            return LUITranslation.error_missing_keys_text.l10n
        case .needsFirstTimePasswordChange:
            return LUITranslation.username_org_dialog_message.l10n
        case .emailAddressAlreadyUsed:
            return LUITranslation.error_email_already_used.l10n
        case .missingSubUserConfiguration:
            return LUITranslation.error_missing_sub_user_configuration.l10n
        case .invalid2FAKey:
            assertionFailure("This should never happen because we don't support 2FAKey yet")
            return LSTranslation._loginservice_error_generic.l10n
        @unknown default:
            return LSTranslation._loginservice_error_generic.l10n
        }
    }
}
