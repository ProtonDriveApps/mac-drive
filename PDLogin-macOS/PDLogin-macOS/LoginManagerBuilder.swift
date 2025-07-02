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
import ProtonCoreNetworking
import ProtonCoreServices
import ProtonCoreEnvironment

public protocol LoginManagerBuilder {
    @MainActor
    func build(in window: NSWindow, completion: @escaping (LoginResult) async -> Void) -> LoginManager
}

public class ConcreteLoginManagerBuilder: LoginManagerBuilder {
    private let environment: Environment
    private let apiServiceDelegate: APIServiceDelegate
    private let forceUpgradeDelegate: ForceUpgradeDelegate

    public init(environment: Environment, apiServiceDelegate: APIServiceDelegate, forceUpgradeDelegate: ForceUpgradeDelegate) {
        self.environment = environment
        self.apiServiceDelegate = apiServiceDelegate
        self.forceUpgradeDelegate = forceUpgradeDelegate
    }

    @MainActor
    public func build(in window: NSWindow, completion: @escaping (LoginResult) async -> Void) -> LoginManager {
        ConcreteLoginManager(
            window: window,
            clientApp: .drive,
            environment: environment,
            apiServiceDelegate: apiServiceDelegate,
            forceUpgradeDelegate: forceUpgradeDelegate,
            minimumAccountType: .external,
            loginCompletion: completion
        )
    }
}
