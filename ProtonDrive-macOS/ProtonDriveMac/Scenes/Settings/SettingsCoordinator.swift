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

protocol SettingsCoordinatorDelegate: AnyObject {
    func reportIssue()
    func showLogsInFinder() async throws
    func userRequestedSignOut() async
    func refreshUserInfo() async throws
}

@MainActor
final class SettingsCoordinator: NSObject, NSWindowDelegate {
    #if HAS_QA_FEATURES
    @SettingsStorage("useLegacyStartOnBootAPI") var useLegacyStartOnBootAPI: Bool?
    #endif
    private weak var delegate: SettingsCoordinatorDelegate?
    private let initialServices: InitialServices
    #if HAS_BUILTIN_UPDATER
    private let appUpdateService: any AppUpdateServiceProtocol
    #endif
    private var window: NSWindow?
    private let launchOnBootService: any LaunchOnBootServiceProtocol
    private lazy var releaseNotesCoordinator = ReleaseNotesCoordinator()

    #if HAS_BUILTIN_UPDATER
    init(delegate: SettingsCoordinatorDelegate,
         initialServices: InitialServices,
         launchOnBootService: any LaunchOnBootServiceProtocol,
         appUpdateService: any AppUpdateServiceProtocol) {
        self.delegate = delegate
        self.initialServices = initialServices
        self.launchOnBootService = launchOnBootService
        self.appUpdateService = appUpdateService
    }
    #else
    init(delegate: SettingsCoordinatorDelegate,
         initialServices: InitialServices,
         launchOnBootService: any LaunchOnBootServiceProtocol) {
        self.delegate = delegate
        self.initialServices = initialServices
        self.launchOnBootService = launchOnBootService
    }
    #endif

    func start() {
        if window == nil {
            configureWindow()
            Task {
                try await updateUserInfo()
            }
        }

        bringWindowToFront()
    }

    private func configureWindow() {
        #if HAS_BUILTIN_UPDATER
        let viewModel = SettingsViewModel(delegate: self,
                                          sessionVault: initialServices.sessionVault,
                                          launchOnBootService: launchOnBootService,
                                          appUpdateService: appUpdateService)
        #else
        let viewModel = SettingsViewModel(delegate: self,
                                          sessionVault: initialServices.sessionVault,
                                          launchOnBootService: launchOnBootService)
        #endif
        let view = SettingsView(viewModel: viewModel)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Proton Drive Settings"
        window.setFrame(.init(origin: window.frame.origin, size: view.idealSize), display: true)
        window.setAccessibilityIdentifier("SettingsCoordinator.window")
        window.delegate = self
        self.window = window
    }

    private func bringWindowToFront() {
        window!.makeKeyAndOrderFront(self)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    private func updateUserInfo() async throws {
        try await delegate?.refreshUserInfo()
    }

    func stop() {
        self.window?.close()
        self.window = nil
    }
    
    func windowWillClose(_ notification: Notification) {
        self.window = nil
    }
}

extension SettingsCoordinator: SettingsViewModelDelegate {
    func userRequestedSignOut() async {
        await delegate?.userRequestedSignOut()
    }
    
    func reportIssue() {
        delegate?.reportIssue()
    }
    
    func showLogsInFinder() async throws {
        try await delegate?.showLogsInFinder()
    }
    
    func showReleaseNotes() {
        releaseNotesCoordinator.start()
    }
}
