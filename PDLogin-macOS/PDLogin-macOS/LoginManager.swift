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
import enum ProtonCoreDataModel.ClientApp
import ProtonCoreLogin
import ProtonCoreNetworking
import ProtonCoreServices
import ProtonCoreUIFoundations
import ProtonCoreEnvironment

@MainActor
public protocol LoginManager {
    func presentLoginFlow(with initialError: LoginError?)
}

@MainActor
public final class ConcreteLoginManager: LoginManager {
    private let loginCoordinatorDelegate: LoginCoordinatorDelegate
    private var loginCoordinator: LoginCoordinator
    
    public init(window: NSWindow,
                clientApp: ClientApp,
                environment: Environment,
                apiServiceDelegate: APIServiceDelegate,
                forceUpgradeDelegate: ForceUpgradeDelegate,
                minimumAccountType: AccountType,
                loginCompletion: @escaping (LoginResult) -> Void) {
        self.loginCoordinatorDelegate = LoginManagerCoordinatorDelegate(loginCompletion)
        let container = Container(clientApp: clientApp,
                                  environment: environment,
                                  apiServiceDelegate: apiServiceDelegate,
                                  forceUpgradeDelegate: forceUpgradeDelegate,
                                  minimumAccountType: minimumAccountType)

        loginCoordinator = LoginCoordinator(container: container,
                                            delegate: loginCoordinatorDelegate,
                                            window: window)
    }

    public func presentLoginFlow(with initialError: LoginError? = nil) {
        loginCoordinator.start(with: initialError)
    }
}

private final class LoginManagerCoordinatorDelegate: LoginCoordinatorDelegate {
    private let loginCompletion: (LoginResult) -> Void

    init(_ loginCompletion: @escaping (LoginResult) -> Void) {
        self.loginCompletion = loginCompletion
    }

    func userDidDismissLoginCoordinator(loginCoordinator: LoginCoordinator) {
        loginCompletion(.dismissed)
    }
    
    func loginCoordinatorDidFinish(loginCoordinator: LoginCoordinator, data: LoginData) {
        loginCompletion(.loggedIn(data))
    }
}
