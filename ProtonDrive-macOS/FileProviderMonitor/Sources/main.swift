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

@MainActor
class FileProviderMonitor {
    let app = NSApplication.shared
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let processObserver = ProcessObserver()

    init () {
        app.setActivationPolicy(.accessory) // Prevents the app from appearing in the Dock
        statusItem.button?.title = "🔵"
    }

    func start() async {
        processObserver.startTimer { [unowned self] status in
            Task {
                await onTick(status: status)
            }
        }

        app.run()
    }

    private func onTick(status: FileProviderStatus) {
        let menu = NSMenu()
        statusItem.menu = menu

        menu.items.removeAll()

        let descriptionMenuItem = NSMenuItem(title: "\(status.description)", action: #selector(self.noop), keyEquivalent: "")
        descriptionMenuItem.target = self
        menu.addItem(descriptionMenuItem)

        let quitMenuItem = NSMenuItem(title: "Quit", action: #selector(self.quit), keyEquivalent: "q")
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)

        self.statusItem.button?.title = status.iconColor
    }

    @objc func noop() {}

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}

let monitor = FileProviderMonitor()
await monitor.start()
