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
import TrustKit
import ProtonCoreAPIClient
import ProtonCoreAuthentication
import ProtonCoreDataModel
import ProtonCoreHumanVerification
import ProtonCoreLogin
import ProtonCoreNetworking
import ProtonCoreServices
import ProtonCoreEnvironment

#if LOAD_TESTING && SSL_PINNING
#error("Load testing requires turning off SSL pinning, so it cannot be set for SSL-pinning targets")
#endif

final class Container {
    private let login: Login
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
        #if LOAD_TESTING && !SSL_PINNING
        api.getSession()?.setChallenge(noTrustKit: true, trustKit: nil)
        #endif
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
        return LoginViewModel(login: login)
    }

    func makeMailboxPasswordViewModel() -> MailboxPasswordViewModel {
        return MailboxPasswordViewModel(login: login)
    }

    func makeTwoFactorViewModel() -> TwoFactorViewModel {
        return TwoFactorViewModel(login: login)
    }
}

extension Container {
    func executeDohTroubleshootMethodFromApiDelegate() {
        api.serviceDelegate?.onDohTroubleshot()
    }
}
