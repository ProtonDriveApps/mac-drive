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
import SwiftUI
import PDCore

@MainActor
final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {

#if HAS_QA_FEATURES
    @SettingsStorage("useLegacyStartOnBootAPI") var useLegacyStartOnBootAPI: Bool?
#endif
    private let sessionVault: SessionVault
    private let appUpdateService: AppUpdateServiceProtocol?
    private var window: NSWindow?
    private let launchOnBootService: any LaunchOnBootServiceProtocol
    private let userActions: UserActions
    private let isFullResyncEnabled: () -> Bool

    init(sessionVault: SessionVault,
         launchOnBootService: any LaunchOnBootServiceProtocol,
         userActions: UserActions,
         appUpdateService: AppUpdateServiceProtocol?,
         isFullResyncEnabled: @escaping () -> Bool) {
        self.sessionVault = sessionVault
        self.launchOnBootService = launchOnBootService
        self.userActions = userActions
        self.appUpdateService = appUpdateService
        self.isFullResyncEnabled = isFullResyncEnabled
    }

    fileprivate func showPopupInformingAboutSettingsWindowUnavailability() {
        DispatchQueue.main.async {
            let error = NSError(
                domain: "me.proton.drive",
                code: 0,
                userInfo: [
                    NSLocalizedDescriptionKey: "Settings windows cannot be opened right now.\n\nPlease try again later."
                ]
            )
            let alert = NSAlert(error: error)
            alert.addButton(withTitle: "Ok")
            _ = alert.runModal()
        }
    }
    
    func start() {
        if window == nil {
            guard configureWindow() else {
                showPopupInformingAboutSettingsWindowUnavailability()
                return
            }
            userActions.account.refreshUserInfo()
        }

        bringWindowToFront()
    }

    private func configureWindow() -> Bool {
        let viewModel = SettingsViewModel(sessionVault: sessionVault,
                                          launchOnBootService: launchOnBootService,
                                          appUpdateService: appUpdateService,
                                          userActions: userActions,
                                          isFullResyncEnabled: isFullResyncEnabled())
        guard let viewModel else { return false }
        let view = SettingsView(viewModel: viewModel)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Proton Drive Settings"
        window.setFrame(.init(origin: window.frame.origin, size: view.idealSize), display: true)
        window.setAccessibilityIdentifier("SettingsCoordinator.window")
        window.delegate = self
        self.window = window
        return true
    }

    private func bringWindowToFront() {
        guard let window else { return }
        window.makeKeyAndOrderFront(self)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    func stop() {
        self.window?.close()
        self.window = nil
    }

    func windowWillClose(_ notification: Notification) {
        self.window = nil
    }

    deinit {
        Log.trace()
    }
}
