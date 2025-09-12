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

import AuthenticationServices
import Foundation
import TrustKit
import ProtonCoreAPIClient
import ProtonCoreAuthentication
import ProtonCoreDataModel
import ProtonCoreHumanVerification
import ProtonCoreLogin
import ProtonCoreNetworking
import ProtonCoreServices
import ProtonCoreEnvironment

final class Container {
    let login: Login
    private let authManager: AuthHelper
    private let api: PMAPIService
    private let humanVerifier: HumanCheckHelper

    init(clientApp: ClientApp,
         environment: Environment,
         apiServiceDelegate: APIServiceDelegate,
         forceUpgradeDelegate: ForceUpgradeDelegate,
         minimumAccountType: AccountType) {
        if PMAPIService.trustKit == nil {
            let trustKit = TrustKit()
            trustKit.pinningValidator = .init()
            PMAPIService.trustKit = trustKit
        }
        api = PMAPIService.createAPIServiceWithoutSession(environment: environment,
                                                          challengeParametersProvider: .empty)
        api.forceUpgradeDelegate = forceUpgradeDelegate
        api.serviceDelegate = apiServiceDelegate
        // this is just an in-memory cache. It doesn't store the credentials to keychain
        authManager = AuthHelper()
        api.authDelegate = authManager

        humanVerifier = HumanCheckHelper(apiService: api, clientApp: .drive)
        api.humanDelegate = humanVerifier
        login = LoginService(api: api, clientApp: clientApp, minimumAccountType: minimumAccountType)
    }

    // MARK: Login view models

    func makeLoginViewModel() -> LoginViewModel {
        return LoginViewModel(login: login, domain: self.api.signUpDomain)
    }

    func makeMailboxPasswordViewModel() -> MailboxPasswordViewModel {
        return MailboxPasswordViewModel(login: login)
    }

    func makeTwoFAWithOneTimeCodeViewModel() -> TwoFAWithOneTimeCodeViewModel {
        return TwoFAWithOneTimeCodeViewModel(login: login)
    }
    
    func makeTwoFAWithSecurityKeyViewModel(
        options: AuthenticationOptions, presentationAnchor: ASPresentationAnchor
    ) -> TwoFAWithSecurityKeyViewModel {
        return TwoFAWithSecurityKeyViewModel(
            login: login, authenticationOptions: options, presentationAnchor: presentationAnchor
        )
    }
}

extension Container {
    func executeDohTroubleshootMethodFromApiDelegate() {
        api.serviceDelegate?.onDohTroubleshot()
    }
}
