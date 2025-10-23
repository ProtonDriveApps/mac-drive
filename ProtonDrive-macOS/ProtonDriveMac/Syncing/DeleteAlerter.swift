// Copyright (c) 2025 Proton AG
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

import Combine
import AppKit
import PDCore

class DeleteAlerter {
    @SettingsStorage("deleteAlertShown") private var deleteAlertShown: Bool?

    private var displaying = false

    private let onlineTrashURL: URL = URL(string: "https://drive.proton.me/trash")!

#if DEBUG && !canImport(XCTest)
    /// How many times has this been instantiated.
    private static var counter = 0

    init() {
        Self.counter += 1

        // Make sure this is only instantiated once only if we're not running tests
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            assert(Self.counter == 1)
        }
    }
#endif

    func showAlert(for email: String?) {
        guard !displaying else { return }
        guard deleteAlertShown != true else { return }

        let alert = NSAlert()
        alert.messageText = "Deleted cloud-only files can be recovered from Trash on the web"
        alert.informativeText = "Files deleted from your Mac that are cloud-only will be permanently removed from your computer but can still be restored from Proton Drive Trash on the web. Files stored locally will be moved to your Mac's Trash."

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Trash")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't show this message again"

        let screenRect = NSScreen.main?.visibleFrame ?? .zero
        let windowSize = NSSize(width: 1, height: 1)

        // offset to have the alert centered
        let windowOrigin = NSPoint(x: screenRect.width / 2, y: (screenRect.height + 340) / 2)
        let window = NSWindow(contentRect: NSRect(origin: windowOrigin, size: windowSize),
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false,
                              screen: NSScreen.main!)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .popUpMenu
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])

        displaying = true

        alert.beginSheetModal(for: window) { [weak self] response in
            if let suppressionButton = alert.suppressionButton, suppressionButton.state == .on {
                self?.deleteAlertShown = true
            }

            if response == .alertSecondButtonReturn { // open trash
                self?.openTrashOnline(for: email)
            }

            self?.displaying = false
        }
    }

    private func openTrashOnline(for email: String?) {
        Log.trace()
        var url = onlineTrashURL
        if let email {
            url.append(queryItems: [URLQueryItem(name: "email", value: email)])
        }
        _ = NSWorkspace.shared.open(url)
    }
}
