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
import SwiftUI
import PDCore

/// Handles clicks on the status menu icon, and creating/destroing the status menu window.
/// Note: An instance of MainWindowCoordinator is created only after the menu bar status icon is clicked, and exists only as long as the window is open.
@MainActor
final class MainWindowCoordinator: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    let state: ApplicationState
    let userActions: UserActions

    init(_ state: ApplicationState, userActions: UserActions) {
        self.state = state
        self.userActions = userActions
    }

    private var globalMouseAndKeyboardEventMonitor: Any?
    private var globalMouseEventMonitor: Any?

    /// Returns true if window was shown, not hidden.
    @discardableResult
    func toggleMenu(from button: NSButton) -> Bool {
        if let window, window.isVisible {
            stop()
            return false
        } else {
            start(from: button)
            return true
        }
    }
    
    var isOpen: Bool {
        window?.isVisible == true
    }

    func start(from button: NSButton) {
        if window == nil {
            configureWindow(from: button)
        }

        bringWindowToFront(from: button)
    }

    func stop() {
        window?.close()
        if let monitor = globalMouseAndKeyboardEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseAndKeyboardEventMonitor = nil
        }
        if let monitor = globalMouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            self.globalMouseEventMonitor = nil
        }
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: window)
    }

    private func configureWindow(from button: NSButton) {
        let mainWindow = MainWindow(state: state, actions: userActions)
        let hostingController = NSHostingController(rootView: mainWindow)

        let screen = NSScreen.main!
        let windowWidth: CGFloat = MainWindow.size.width
        let windowHeight: CGFloat = MainWindow.size.height
        let buttonRect = button.window?.frame ?? NSRect()
        let windowRect = NSRect(x: buttonRect.midX - windowWidth / 2, y: buttonRect.maxY - windowHeight, width: windowWidth, height: windowHeight)

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

        self.globalMouseAndKeyboardEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak button] event in
            guard let self = self, let button = button else {
                return event
            }
            switch event.type {
            case .leftMouseDown, .rightMouseDown:
                if event.isStatusItemButtonClicked(button: button) {
                    _ = self.toggleMenu(from: button)
                }
            default:
                break
            }

            return event
        }

        self.globalMouseEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
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
        if let window {
            let screenFrame = getCurrentScreen().frame
            let buttonRect = button.window?.frame ?? NSRect()
            let idealX = buttonRect.midX - MainWindow.size.width / 2
            let requiredX = screenFrame.origin.x + screenFrame.width - MainWindow.size.width
            let requiredY = screenFrame.origin.y + screenFrame.height - MainWindow.size.height
            window.setFrameOrigin(NSPoint(
                x: min(idealX, requiredX),
                y: requiredY
            ))
        }
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        }
    }

    private func getCurrentScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let currentScreen = screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main!
        return currentScreen
    }

    deinit {
        Log.trace()
    }
    
    // MARK: - NSWindowDelegate
    
    func windowWillClose(_ notification: Notification) {
        self.window = nil
    }

    func windowDidResignKey(_ notification: Notification) {
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
