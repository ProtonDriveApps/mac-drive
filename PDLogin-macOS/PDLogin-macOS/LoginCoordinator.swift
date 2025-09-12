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
import Combine
import SwiftUI
import ProtonCoreAuthentication
import ProtonCoreLogin
import ProtonCoreNetworking
import ProtonCoreServices
import ProtonCoreUIFoundations

protocol LoginCoordinatorDelegate: AnyObject {
    func loginCoordinatorDidFinish(loginCoordinator: LoginCoordinator, data: LoginData) async
}

@MainActor
final class LoginCoordinator: NSObject {
    weak var delegate: LoginCoordinatorDelegate?

    private let windowController: NSWindowController
    private let window: NSWindow
    private let container: Container

    private var vm: LoginViewModel?

    private var finishedSubscription: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    init(container: Container, delegate: LoginCoordinatorDelegate, window: NSWindow) {
        self.window = window
        self.window.setAccessibilityIdentifier("LoginCoordinator.window")
        self.windowController = NSWindowController()
        self.container = container
        self.delegate = delegate

        super.init()
    }

    func start(with initialError: LoginError? = nil) {
        if windowController.window == nil {
            showInitialView(with: initialError)
        } else if initialError != nil {
            presentAtPreviousScreensOriginAndSize(view: loginView(with: initialError))
        }

        presentExistingView()
    }
    
    private func showInitialView(with initialError: LoginError? = nil) {
        self.windowController.window = window

        present(view: loginView(with: initialError))
    }

    private func presentExistingView() {
        if let window = self.windowController.window, window.isMiniaturized {
            self.windowController.window?.deminiaturize(nil)
        }

        self.windowController.window!.level = .statusBar
        self.windowController.showWindow(self)
        self.windowController.window!.makeKeyAndOrderFront(self)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    private func loginComplete(_ data: LoginData) async {
        await self.delegate?.loginCoordinatorDidFinish(loginCoordinator: self, data: data)
    }

    private func loginStepResultReceived(_ result: LoginStep) async {
        switch result {
        case let .done(data):
            await loginComplete(data)
        case .backToStart(let initialError):
            presentAtPreviousScreensOriginAndSize(view: loginView(with: initialError))
        case .twoFactorCodeNeeded:
            presentAtPreviousScreensOriginAndSize(view: twoFAWithOneTimeCodeView)
        case .mailboxPasswordNeeded:
            presentAtPreviousScreensOriginAndSize(view: secondPasswordView)
        case .securityKeyNeeded(let options):
            presentAtPreviousScreensOriginAndSize(view: twoFAWithSecurityKeyViewModel(options: options))
        case .securityKeyOrTwoFactorCodeNeeded(let options):
            presentAtPreviousScreensOriginAndSize(view: choose2FAView(options: options))
        }
    }

    public func logIn(as username: String, password: String) {
        vm?.username = username
        vm?.password = password
        vm?.logIn()
    }

    private func loginView(with initialError: LoginError? = nil) -> some View {
        let vm = container.makeLoginViewModel()
        self.vm = vm

        finishedSubscription = vm.$finished
            .sink { [unowned self] result in
                guard let result = result else { return }
                Task {
                    await self.loginStepResultReceived(result)
                }
            }

        vm.$isLoading
            .sink { [unowned self] loading in
                self.windowButtonEnabled(!loading)
            }
            .store(in: &cancellables)

        return LoginView(vm: vm, initialError: initialError, window: windowController.window!)
    }

    private var twoFAWithOneTimeCodeView: some View {
        let vm = container.makeTwoFAWithOneTimeCodeViewModel()
        finishedSubscription = vm.$finished
            .sink { [unowned self] result in
                guard let result = result else { return }
                Task {
                    await self.loginStepResultReceived(result)
                }
            }

        vm.$isLoading
            .sink { [unowned self] loading in
                self.windowButtonEnabled(!loading)
            }
            .store(in: &cancellables)

        return TwoFAWithOneTimeCodeView(vm: vm, window: windowController.window!)
    }

    private var secondPasswordView: some View {
        let vm = container.makeMailboxPasswordViewModel()
        finishedSubscription = vm.$finished
            .sink { [unowned self] result in
                guard let result = result else { return }
                Task {
                    await self.loginStepResultReceived(result)
                }
            }

        vm.$isLoading
            .sink { [unowned self] loading in
                self.windowButtonEnabled(!loading)
            }
            .store(in: &cancellables)

        return MailboxPasswordView(vm: vm, window: windowController.window!)
    }
    
    private func twoFAWithSecurityKeyViewModel(options: AuthenticationOptions) -> some View {
        let viewModel = container.makeTwoFAWithSecurityKeyViewModel(options: options, presentationAnchor: windowController.window!)
        finishedSubscription = viewModel.$finished
            .sink { [unowned self] result in
                guard let result = result else { return }
                Task { [weak self] in
                    await self?.loginStepResultReceived(result)
                }
            }
        
        viewModel.$isLoading
            .sink { [unowned self] loading in
                self.windowButtonEnabled(!loading)
            }
            .store(in: &cancellables)

        return TwoFAWithSecurityKeyView(viewModel: viewModel, window: windowController.window!)
    }
    
    private func choose2FAView(options: AuthenticationOptions) -> some View {
        let twoFAWithOneTimeCodeViewModel = container.makeTwoFAWithOneTimeCodeViewModel()
        let twoFAWithSecurityKeyViewModel = container.makeTwoFAWithSecurityKeyViewModel(options: options, presentationAnchor: windowController.window!)
        twoFAWithOneTimeCodeViewModel.$isLoading.merge(with: twoFAWithSecurityKeyViewModel.$isLoading)
            .sink { [unowned self] loading in
                self.windowButtonEnabled(!loading)
            }
            .store(in: &cancellables)
        
        finishedSubscription = twoFAWithOneTimeCodeViewModel.$finished.merge(with: twoFAWithSecurityKeyViewModel.$finished)
            .sink { [unowned self] result in
                guard let result = result else { return }
                Task { [weak self] in
                    await self?.loginStepResultReceived(result)
                }
            }
        
        return ChooseTwoFAView(twoFAWithOneTimeCodeViewModel: twoFAWithOneTimeCodeViewModel,
                               twoFAWithSecurityKeyViewModel: twoFAWithSecurityKeyViewModel,
                               window: windowController.window!)
    }

    private func presentAtPreviousScreensOriginAndSize<Content: View>(view: Content) {
        let windowOrigin = windowController.window!.frame.origin
        let contentSize = windowController.window!.contentRect(forFrameRect: windowController.window!.frame).size

        let sizedView = view.frame(width: contentSize.width, height: contentSize.height)

        present(view: sizedView)

        self.windowController.window!.setFrameOrigin(windowOrigin)
    }

    private func present<Content: View>(view: Content) {
        let hostingController = NSHostingController(rootView: view)
        self.windowController.contentViewController = hostingController
    }

    private func windowButtonEnabled(_ enabled: Bool) {
        window.standardWindowButton(NSWindow.ButtonType.closeButton)?.isEnabled = enabled
    }
}
