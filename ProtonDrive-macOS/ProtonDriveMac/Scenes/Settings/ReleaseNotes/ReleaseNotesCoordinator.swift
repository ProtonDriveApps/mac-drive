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
final class ReleaseNotesCoordinator: NSObject, NSWindowDelegate {
    
    private var window: NSWindow?
    
    func start() {
        if window == nil {
            configureWindow()
        }

        bringWindowToFront()
    }

    private func configureWindow() {
        let viewModel = ReleaseNotesViewModel()
        let view = ReleaseNotesView(viewModel: viewModel)
        let vc = NSViewController()
        vc.view = view
        let window = NSWindow(contentViewController: vc)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "Release Notes"
        window.minSize = view.minimalSize
        window.setFrame(.init(origin: window.frame.origin, size: view.idealSize), display: true)
        window.setAccessibilityIdentifier("ReleaseNotesCoordinator.window")
        window.delegate = self
        self.window = window
    }

    private func bringWindowToFront() {
        window!.makeKeyAndOrderFront(self)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    func stop() {
        self.window?.close()
        self.window = nil
    }
    
    func windowWillClose(_ notification: Notification) {
        self.window = nil
    }
}
