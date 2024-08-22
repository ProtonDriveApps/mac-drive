// Copyright (c) 2024 Proton AG
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
import Combine
import SwiftUI
import PDCore

@MainActor
final class SyncCoordinator: NSObject, NSWindowDelegate {
    private let metadataMonitor: MetadataMonitor?
    private let communicationService: CoreDataCommunicationService<SyncItem>?
    private let initialServices: InitialServices
    private let delegate: MenuBarDelegate?
    private let baseURL: URL?
    private var window: NSWindow?
    #if HAS_BUILTIN_UPDATER
    private let appUpdateService: any AppUpdateServiceProtocol
    #endif

    private let syncStateService: SyncStateService

    private let syncActivityViewModel: SyncActivityViewModel

    private let getMoreStorageURL: URL = URL(string: "https://account.proton.me/drive/dashboard")!

    private let driveURL: URL = URL(string: "https://drive.proton.me")!

    private var cancellables = Set<AnyCancellable>()

    private var eventsMonitor: Any?
    private var globalMonitor: Any?

    #if HAS_BUILTIN_UPDATER
    init(metadataMonitor: MetadataMonitor?,
         communicationService: CoreDataCommunicationService<SyncItem>?,
         initialServices: InitialServices,
         appUpdateService: any AppUpdateServiceProtocol,
         syncStateService: SyncStateService,
         delegate: MenuBarDelegate?,
         baseURL: URL?) {
        self.metadataMonitor = metadataMonitor
        self.communicationService = communicationService
        self.initialServices = initialServices
        self.appUpdateService = appUpdateService
        self.syncStateService = syncStateService
        self.delegate = delegate
        self.baseURL = baseURL
        self.syncActivityViewModel = SyncActivityViewModel(
            metadataMonitor: metadataMonitor,
            sessionVault: initialServices.sessionVault,
            communicationService: self.communicationService,
            appUpdateService: appUpdateService,
            syncStateService: syncStateService,
            delegate: delegate,
            itemBaseURL: baseURL,
            signInAction: delegate?.showLogin
        )
    }
    #else
    init(metadataMonitor: MetadataMonitor?,
         communicationService: CoreDataCommunicationService<SyncItem>?,
         initialServices: InitialServices,
         syncStateService: SyncStateService,
         delegate: MenuBarDelegate?,
         baseURL: URL?) {
        self.metadataMonitor = metadataMonitor
        self.communicationService = communicationService
        self.initialServices = initialServices
        self.syncStateService = syncStateService
        self.delegate = delegate
        self.baseURL = baseURL
        self.syncActivityViewModel = SyncActivityViewModel(
            metadataMonitor: metadataMonitor,
            sessionVault: initialServices.sessionVault,
            communicationService: self.communicationService,
            syncStateService: syncStateService,
            delegate: delegate,
            itemBaseURL: baseURL,
            signInAction: delegate?.showLogin
        )
    }
    #endif

    func toggleMenu(from button: NSButton, menuBarState: SyncStateService.MenuBarState) {
        syncActivityViewModel.updateOverallState(menuBarState)
        guard let currentWindow = window else {
            configureWindow(from: button)
            bringWindowToFront(from: button)
            return
        }

        if currentWindow.isVisible {
            stop()
        } else {
            bringWindowToFront(from: button)
        }
    }

    func stop() {
        window?.close()
        if let monitor = eventsMonitor {
            NSEvent.removeMonitor(monitor)
            eventsMonitor = nil
        }
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: window)
    }

    private func configureWindow(from button: NSButton) {
        let activityView = SyncActivityView(vm: syncActivityViewModel)
        let hostingController = NSHostingController(rootView: activityView)

        let screen = NSScreen.main!
        let windowWidth: CGFloat = activityView.size.width
        let windowHeight: CGFloat = activityView.size.height
        let screenRect = button.window?.frame ?? NSRect()
        let windowRect = NSRect(x: screenRect.midX - windowWidth / 2, y: screenRect.maxY - windowHeight, width: windowWidth, height: windowHeight)

        let window = NSWindow(contentRect: windowRect, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false, screen: screen)
        window.contentViewController = hostingController
        window.level = .popUpMenu
        window.isReleasedWhenClosed = false

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        window.isMovable = false
        window.isMovableByWindowBackground = false

        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        window.hidesOnDeactivate = false

        window.delegate = self
        self.window = window

        configureEvents(button: button)
    }

    private func configureEvents(button: NSButton) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(checkWindowFocus),
            name: NSApplication.didBecomeActiveNotification,
            object: window
        )

        self.eventsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak button] event in
            guard let self = self, let button = button else {
                return event
            }
            switch event.type {
            case .leftMouseDown, .rightMouseDown:
                if event.isStatusItemButtonClicked(button: button) {
                    self.toggleMenu(from: button, menuBarState: self.syncStateService.menuBarState)
                }
            default:
                break
            }

            return event
        }

        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return }
            self.handleGlobalMouseEvent(event)
        }
    }

    private func handleGlobalMouseEvent(_ event: NSEvent) {
        guard let window = self.window else { return }
        let windowRect = window.frame
        let screenLocation = NSEvent.mouseLocation
        if !windowRect.contains(screenLocation) {
            self.stop()
        }
    }

    @objc private func checkWindowFocus() {
        if !isWindowOnCurrentScreen() {
            self.window?.close()
        }
    }

    private func isWindowOnCurrentScreen() -> Bool {
        guard let window = self.window else { return true }
        let currentScreen = getCurrentScreen()
        return currentScreen.frame.intersects(window.frame)
    }

    private func bringWindowToFront(from button: NSButton) {
        let screenRect = button.window?.frame ?? NSRect()
        if let window {
            window.setFrameOrigin(NSPoint(
                x: screenRect.midX - window.frame.width / 2,
                y: screenRect.maxY - window.frame.height / 2)
            )
        }
        window?.makeKeyAndOrderFront(nil)
    }

    private func getCurrentScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let currentScreen = screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main!
        return currentScreen
    }

    // MARK: - NSWindowDelegate
    
    func windowWillClose(_ notification: Notification) {
        self.window = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        syncStateService.startTimer()
    }

    func windowDidResignKey(_ notification: Notification) {
        syncStateService.invalidateTimer()
        window?.orderOut(nil)
    }
}

private extension NSEvent {

    func isStatusItemButtonClicked(button: NSButton) -> Bool {
        guard let window = window else { return false }
        guard window.className.hasPrefix("NSStatusBar"), window.className.hasSuffix("Window") else { return false }
        return window.contentView?.subviews.contains(button) ?? false
    }
}
