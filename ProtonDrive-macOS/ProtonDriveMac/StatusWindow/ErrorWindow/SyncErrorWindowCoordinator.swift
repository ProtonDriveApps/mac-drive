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
final class SyncErrorWindowCoordinator {

    private var window: NSWindow?

    private let state: ApplicationState
    private let actions: UserActions

    init(state: ApplicationState, actions: UserActions) {
        self.state = state
        self.actions = actions
    }

    func start() {
        if window == nil {
            configureWindow()
        }
        bringWindowToFront()
    }

    func stop() {
        window?.close()
    }
    
    private func configureWindow() {
        let view = SyncErrorWindow(state: state, userActions: actions, closeAction: stop)

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = "Sync Errors"
        window.setFrame(.init(origin: window.frame.origin, size: view.idealSize), display: true)
        window.level = .statusBar
        window.setAccessibilityIdentifier("SyncErrorWindowCoordinator.window")
        self.window = window
    }

    private func bringWindowToFront() {
        window?.makeKeyAndOrderFront(self)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    deinit {
        Log.trace()
    }
}
