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
final class ErrorCoordinator {

    private let storageManager: SyncStorageManager?
    private let communicationService: CoreDataCommunicationService<SyncItem>?
    private let baseURL: URL
    private var window: NSWindow?

    @MainActor
    init(storageManager: SyncStorageManager?, communicationService: CoreDataCommunicationService<SyncItem>?, baseURL: URL) {
        self.storageManager = storageManager
        self.communicationService = communicationService
        self.baseURL = baseURL
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
        if let storageManager {
            let viewModel = SyncErrorViewModel(
                storageManager: storageManager,
                communicationService: self.communicationService,
                baseURL: baseURL,
                closeHandler: stop
            )
            let view = SyncErrorView(vm: viewModel)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.title = "Sync Errors"
            window.setFrame(.init(origin: window.frame.origin, size: view.idealSize), display: true)
            window.level = .statusBar
            window.setAccessibilityIdentifier("ErrorCoordinator.window")
            self.window = window
        }
    }

    private func bringWindowToFront() {
        window?.makeKeyAndOrderFront(self)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

}
