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
import PDClient
import PDCore
import ProtonCoreServices

@MainActor
final class QASettingsWindowCoordinator: NSObject, NSWindowDelegate {
    private let dumperDependencies: DumperDependencies?
    private let signoutManager: SignoutManager?
    private let sessionStore: SessionVault
    private let mainKeyProvider: MainKeyProvider
    private let eventLoopManager: EventLoopManager?
    private let featureFlags: PDCore.FeatureFlagsRepository?
    private let appUpdateService: AppUpdateServiceProtocol?
    private let applicationEventObserver: ApplicationEventObserver
    private let metadataStorage: StorageManager?
    private let eventsStorage: EventStorageManager?
    private let jailDependencies: (PMAPIService, Client)?

    private let userActions: UserActions

    private var window: NSWindow?

    init(signoutManager: SignoutManager?,
         sessionStore: SessionVault,
         mainKeyProvider: MainKeyProvider,
         appUpdateService: AppUpdateServiceProtocol?,
         eventLoopManager: EventLoopManager?,
         featureFlags: PDCore.FeatureFlagsRepository?,
         dumperDependencies: DumperDependencies?,
         userActions: UserActions,
         applicationEventObserver: ApplicationEventObserver,
         metadataStorage: StorageManager?,
         eventsStorage: EventStorageManager?,
         jailDependencies: (PMAPIService, Client)?
    ) {
        self.signoutManager = signoutManager
        self.sessionStore = sessionStore
        self.mainKeyProvider = mainKeyProvider
        self.appUpdateService = appUpdateService
        self.eventLoopManager = eventLoopManager
        self.featureFlags = featureFlags
        self.dumperDependencies = dumperDependencies
        self.userActions = userActions
        self.applicationEventObserver = applicationEventObserver
        self.metadataStorage = metadataStorage
        self.eventsStorage = eventsStorage
        self.jailDependencies = jailDependencies
    }

    func start() {
        if window == nil {
            configureWindow()
        }

        bringWindowToFront()
    }

    private func configureWindow() {
        let vm = QASettingsViewModel(
            signoutManager: signoutManager,
            sessionStore: sessionStore,
            mainKeyProvider: mainKeyProvider,
            appUpdateService: appUpdateService,
            eventLoopManager: eventLoopManager,
            featureFlags: featureFlags,
            dumperDependencies: dumperDependencies,
            applicationEventObserver: applicationEventObserver,
            userActions: userActions,
            metadataStorage: metadataStorage,
            eventsStorage: eventsStorage,
            jailDependencies: jailDependencies,
            promoCampaignInteractor: PromoCampaignInteractor.shared
        )

        let view = QASettingsView(vm: vm)

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.styleMask = [.titled, .closable]
        window.title = "QA Settings"
        window.level = .statusBar
        window.delegate = self
        window.setAccessibilityIdentifier("SettingsWindowCoordinator.window")

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

    deinit {
        Log.trace()
    }
}

#endif
