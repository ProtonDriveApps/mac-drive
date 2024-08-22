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
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    
    private static let protonDriveAppIdentifier = "ch.protonmail.drive"
    
    private let logger = Logger(.default)
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("ProtonDriveMacLauncher started")

        // Ensures the app is not already running
        guard NSRunningApplication.runningApplications(withBundleIdentifier: AppDelegate.protonDriveAppIdentifier).isEmpty else {
            logger.info("Proton Drive app already running, exiting")
            NSApp.terminate(nil)
            return
        }
        
        logger.info("Proton Drive app not running, launching...")

        let pathComponents = (Bundle.main.bundlePath as NSString).pathComponents
        let mainPath = NSString.path(withComponents: Array(pathComponents[0...(pathComponents.count - 5)]))
        let mainURL = URL(fileURLWithPath: mainPath)
        let configuration: NSWorkspace.OpenConfiguration = .init()
        let logger = self.logger
        NSWorkspace.shared.openApplication(at: mainURL, configuration: configuration) { runningApplication, error in
            switch (runningApplication, error) {
            case (nil, nil):
                logger.error("Launching Proton Drive app failed but no error provided")
            case (nil, let error?):
                logger.error("Launching Proton Drive app failed with error \(error)")
            case (_?, nil):
                logger.info("Launching Proton Drive app succeeded")
            case (_?, let error?):
                logger.info("Launching Proton Drive app succeeded but with error \(error)")
            }
            NSApp.terminate(nil)
        }
    }
}

private let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()
