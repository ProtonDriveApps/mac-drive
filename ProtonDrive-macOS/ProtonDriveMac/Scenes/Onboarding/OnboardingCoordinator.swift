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
import Combine
import Foundation
import PDCore
import PDLogin_macOS
import ProtonCoreUIFoundations
import SwiftUI

@MainActor
final class OnboardingCoordinator: NSObject {

    private weak var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    init(window: NSWindow?) {
        self.window = window
    }

    func start() {
        let onboardingController = OnboardingController()
        window?.standardWindowButton(NSWindow.ButtonType.closeButton)?.isEnabled = true
        window?.contentView = NSHostingView(rootView: OnboardingView(controller: onboardingController))
        window?.setAccessibilityIdentifier("OnboardingCoordinator.window")

        onboardingController.finishSubject
            .sink { [weak self] in
                self?.end()
            }
            .store(in: &cancellables)
    }

    func end() {
        window?.close()
        window = nil
    }
}
