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

#if HAS_QA_FEATURES

import AppKit
import SwiftUI
import PDCore

@MainActor
final class QASettingsCoordinator: NSObject, NSWindowDelegate {
    private let dumperDependencies: DumperDependencies?
    private let signoutManager: SignoutManager?
    private let sessionStore: SessionVault
    private let mainKeyProvider: MainKeyProvider
    private let eventLoopManager: EventLoopManager?
    private let featureFlags: PDCore.FeatureFlagsRepository?
    #if HAS_BUILTIN_UPDATER
    private let appUpdateService: SparkleAppUpdateService
    #endif
    private var window: NSWindow?
    
    #if HAS_BUILTIN_UPDATER
    init(signoutManager: SignoutManager?,
         sessionStore: SessionVault,
         mainKeyProvider: MainKeyProvider,
         appUpdateService: SparkleAppUpdateService,
         eventLoopManager: EventLoopManager?,
         featureFlags: PDCore.FeatureFlagsRepository?,
         dumperDependencies: DumperDependencies?
    ) {
        self.dumperDependencies = dumperDependencies
        self.signoutManager = signoutManager
        self.sessionStore = sessionStore
        self.mainKeyProvider = mainKeyProvider
        self.appUpdateService = appUpdateService
        self.eventLoopManager = eventLoopManager
        self.featureFlags = featureFlags
    }
    #else
    init(signoutManager: SignoutManager?,
         sessionStore: SessionVault,
         mainKeyProvider: MainKeyProvider,
         eventLoopManager: EventLoopManager?,
         featureFlags: PDCore.FeatureFlagsRepository?,
         dumperDependencies: DumperDependencies?
    ) {
        self.dumperDependencies = dumperDependencies
        self.signoutManager = signoutManager
        self.sessionStore = sessionStore
        self.mainKeyProvider = mainKeyProvider
        self.eventLoopManager = eventLoopManager
        self.featureFlags = featureFlags
    }
    #endif
    
    func start() {
        if window == nil {
            configureWindow()
        }

        bringWindowToFront()
    }
    
    private func configureWindow() {
        #if HAS_BUILTIN_UPDATER
        let vm = QASettingsViewModel(signoutManager: signoutManager,
                                     sessionStore: sessionStore,
                                     mainKeyProvider: mainKeyProvider,
                                     appUpdateService: appUpdateService,
                                     eventLoopManager: eventLoopManager,
                                     featureFlags: featureFlags,
                                     dumperDependencies: dumperDependencies)
        #else
        let vm = QASettingsViewModel(signoutManager: signoutManager,
                                     sessionStore: sessionStore,
                                     mainKeyProvider: mainKeyProvider,
                                     eventLoopManager: eventLoopManager,
                                     featureFlags: featureFlags,
                                     dumperDependencies: dumperDependencies)
        #endif
        let view = QASettingsView(vm: vm)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.title = "QA Settings"
        window.level = .statusBar
        window.delegate = self
        window.setAccessibilityIdentifier("SettingsCoordinator.window")

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

#endif
