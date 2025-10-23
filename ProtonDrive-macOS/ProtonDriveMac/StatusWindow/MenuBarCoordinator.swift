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

import PDCore
import Combine
import SwiftUI
import PDLocalization

/// Contains all logic related to the status menu icon, its dropdown menu, and opening the status menu window.
@MainActor
final class MenuBarCoordinator: NSObject, ObservableObject, NSMenuDelegate {

    @ObservedObject private var state: ApplicationState

    /// Icon in the status bar
    private(set) var statusItem: NSStatusItem!
    public var button: NSButton? { statusItem.button }

    /// First item in the dropdown menu, showing the current syncing status
    private var syncStatusMenuItem = NSMenuItem()

    private let userActions: UserActions

    private var cancellables: Set<AnyCancellable> = []

    init(state: ApplicationState, userActions: UserActions) {
        self.state = state
        self.userActions = userActions
        super.init()
        self.statusItem = self.makeStatusItem()

        Log.trace()

        state.objectWillChange
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink(receiveValue: { [unowned self] in self.updateIconAndMenu() })
            .store(in: &cancellables)
    }

    deinit {
        Log.trace()
    }

    private func updateIconAndMenu() {
        updateIcon()
        updateMenu()
    }

    /// Used to temporarily override the status shown by the status bar icon to "syncing", to indicate that there is some long-lasting operation in progress.
    public var activityIndicatorEnabled = false {
        didSet {
            guard activityIndicatorEnabled != oldValue else { return }

            Log.trace(activityIndicatorEnabled.description)
            updateIcon()
        }
    }

    // MARK: - Status item

    private func makeStatusItem() -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button!.image = statusItemImage()
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.action = #selector(statusItemTapped(_:))
        statusItem.button?.target = self
        statusItem.button?.setAccessibilityIdentifier("Proton Drive")
        return statusItem
    }

    private func updateIcon() {
        Log.trace()

        statusItem.button?.image = statusItemImage()
    }

    private func statusItemImage() -> NSImage {
        let menuIconStatus = activityIndicatorEnabled ? .syncing : state.overallStatus
        let iconName = statusItemImageName(menuIconStatus)

        Log.trace("\(menuIconStatus), \(iconName), \(activityIndicatorEnabled)")

        let margin = 2
        let size = Int(NSStatusBar.system.thickness) - margin * 2
        return NSImage(named: iconName)!.resize(newWidth: size, newHeight: size)
    }

    private func statusItemImageName(_ status: ApplicationSyncStatus) -> String {
        switch status {
        case .signedOut:
            return "status-signed-out"
        case .paused:
            return "status-paused"
        case .offline:
            return "status-offline"
        case .syncing, .enumerating, .launching, .fullResyncInProgress:
            return "status-syncing"
        case .errored:
            return "status-error"
        case .updateAvailable:
            return "status-update-available"
        case .synced, .fullResyncCompleted:
            if state.visibleCampaign != nil && !state.items.isEmpty {
                return "status-promo"
            } else {
                return "status-synced"
            }
        }
    }

    @objc func statusItemTapped(_ sender: NSButton) {
        Log.trace()
        
        if Constants.isInUITests {
            showOldMenu()
            return
        }

        if let statusButton = statusItem.button,
           let event = NSApp.currentEvent,
           event.type == .leftMouseUp,
           !event.modifierFlags.contains(.option)
        {
            userActions.app.toggleStatusWindow(from: statusButton)
        } else {
            showOldMenu()
        }
    }
    
    func showMenuProgramatically() {
        if let statusButton = statusItem.button {
            userActions.app.showStatusWindow(from: statusButton)
        } else {
            showOldMenu()
        }
    }

    private func showOldMenu() {
        Log.trace()

        if statusItem.menu == nil {
            statusItem.menu = makeStatusMenu()
        }
        statusItem.button?.performClick(nil)
    }

    // MARK: Dropdown menu

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        if case .launching = state.overallStatus {
            menu.addItem(launchingMenuItem)
            return menu
        }
        
        if state.fullResyncState.isHappening {
            if case .completed = state.fullResyncState  {
                menu.addItem(finishFullResyncMenuItem)
            } else {
                menu.addItem(syncStatusMenuItem)
                menu.addItem(cancelFullResyncMenuItem)
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(openDriveMenuItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(quitAppMenuItem)
            return menu
        }

        if state.isLoggedIn {
            menu.addItem(syncStatusMenuItem)

            if case .offline = state.overallStatus{
                menu.addItem(offlineMenuItem)
            }

            if case .errored = state.overallStatus {
                menu.addItem(syncErrorMenuItem)
            }

            menu.addItem(NSMenuItem.separator())
            menu.addItem(eventSyncMenuItem)

            menu.addItem(NSMenuItem.separator())

            menu.addItem(openDriveMenuItem)

#if HAS_BUILTIN_UPDATER
            if state.isUpdateAvailable {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(appUpdateMenuItem)
            }
#endif

            menu.addItem(NSMenuItem.separator())

            menu.addItem(settingsMenuItem)
        } else {
            menu.addItem(loginMenuItem)
            menu.addItem(NSMenuItem.separator())
            // these are added to menu bar only before login,
            // because after login they are available in Settings screen
            menu.addItem(showLogsMenuItem)
            menu.addItem(bugReportMenuItem)
        }

        menu.addItem(NSMenuItem.separator())

#if HAS_QA_FEATURES
        let submenu = NSMenu()
        submenu.addItem(qaSettingsMenuItem)
        submenu.addItem(globalProgressVisibilityMenuItem)
        submenu.addItem(showLogsMenuItem)
        submenu.addItem(performFullResyncMenuItem)
        if state.isLoggedIn {
            submenu.addItem(signoutMenuItem)
        }

        let devOptionsMenuItem = NSMenuItem(title: "Developer options", action: nil, keyEquivalent: "d")
        menu.addItem(devOptionsMenuItem)
        menu.setSubmenu(submenu, for: devOptionsMenuItem)

        menu.addItem(NSMenuItem.separator())
#endif

        menu.addItem(quitAppMenuItem)

        return menu
    }

    private func updateMenu() {
        Log.trace()

        if state.isLoggedIn {
            updateSyncStatusMenuItem()
        }
    }

    func updateSyncStatusMenuItem() {
        Log.trace()

        let presentedStatus: ApplicationSyncStatus
        if state.fullResyncState.isHappening {
            presentedStatus = .fullResyncInProgress
        // If syncing and not paused, show "syncing", otherwise show "synced".
        } else if state.isSyncing && !state.isPaused {
            presentedStatus = .syncing
        } else {
            presentedStatus = .synced
        }
        let imageName = presentedStatus == .syncing || presentedStatus == .fullResyncInProgress ? "syncing" : "synced"

        syncStatusMenuItem.title = state.displayName(for: presentedStatus)
        syncStatusMenuItem.image = NSImage(named: imageName)
        syncStatusMenuItem.action = #selector(UserActions.ApplicationActions.doNothing)
        syncStatusMenuItem.target = userActions.app
        syncStatusMenuItem.isEnabled = true

        // If presentedStatus is syncing, make the label bold
        if case .syncing = presentedStatus {
            let attributes = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 0, weight: .bold),
                              NSAttributedString.Key.foregroundColor: NSColor.selectedMenuItemTextColor]
            let attributedTitle = NSAttributedString(string: self.syncStatusMenuItem.title, attributes: attributes)
            syncStatusMenuItem.attributedTitle = attributedTitle
        } else {
            syncStatusMenuItem.attributedTitle = nil
        }

        let accessibilityIdentifier = state.overallStatus == .synced ? "MenuBarCoordinator.MenuItem.synced" : "MenuBarCoordinator.MenuItem.syncing"
        syncStatusMenuItem.setAccessibilityIdentifier(accessibilityIdentifier)
    }

    // MARK: Menu items

    private var offlineMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(
            title: Localization.menu_offline,
            action: #selector(UserActions.ApplicationActions.doNothing),
            keyEquivalent: ""
        )
        menuItem.target = userActions.app
        menuItem.image = NSImage(named: "cloud-slash")
        menuItem.setAccessibilityIdentifier("MenuBarCoordinator.MenuItem.offline")
        return menuItem
    }

    private var syncErrorMenuItem: NSMenuItem {
        let errorsCountTitle = state.overallStatus.displayLabel
        let menuItem = NSMenuItem(
            title: errorsCountTitle,
            action: #selector(UserActions.WindowActions.showErrorWindow),
            keyEquivalent: ""
        )
        menuItem.target = userActions.windows
        menuItem.image = NSImage(named: "cross-circle")
        menuItem.isHidden = state.errorCount <= 0
        menuItem.setAccessibilityIdentifier("MenuBarCoordinator.MenuItem.syncError")
        return menuItem
    }

    private var launchingMenuItem: NSMenuItem {
        let title = Localization.menu_launching_percentage(launchCompletion: state.launchCompletion)
        let menuItem = NSMenuItem(
            title: title,
            action: #selector(UserActions.ApplicationActions.doNothing),
            keyEquivalent: ""
        )
        menuItem.target = userActions.app
        menuItem.image = NSImage(named: "syncing")
        return menuItem
    }

    private var eventSyncMenuItem: NSMenuItem {
        let isPaused = state.overallStatus == .paused
        let title = isPaused ? Localization.sync_resume : Localization.sync_pause
        let selector = isPaused ? #selector(UserActions.SyncActions.resumeSyncing) : #selector(
            UserActions.SyncActions.pauseSyncing
        )
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        menuItem.image = NSImage(named: isPaused ? "resume" : "pause")
        menuItem.target = userActions.sync
        let accessibilityIdentifier = isPaused ? "MenuBarCoordinator.MenuItem.resumeSyncing" : "MenuBarCoordinator.MenuItem.pauseSyncing"
        menuItem.setAccessibilityIdentifier(accessibilityIdentifier)
        menuItem.keyEquivalent = "p"
        return menuItem
    }

    private var openDriveMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(
            title: "Open Drive Folder",
            action: #selector(openDriveFolder),
            keyEquivalent: "o"
        )
        menuItem.target = self
        return menuItem
    }
    
    @objc private func openDriveFolder() {
        userActions.app.openDriveFolder()
    }
    
    private var cancelFullResyncMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(
            title: "Cancel full resync",
            action: #selector(UserActions.ResyncActions.cancelFullResync),
            keyEquivalent: ""
        )
        menuItem.target = userActions.resync
        return menuItem
    }
    
    private var finishFullResyncMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(
            title: "Finish full resync",
            action: #selector(finishFullResync),
            keyEquivalent: ""
        )
        menuItem.target = self
        return menuItem
    }
    
    @objc private func finishFullResync() {
        userActions.resync.finishFullResync()
    }

#if HAS_BUILTIN_UPDATER
    private var appUpdateMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(title: "Install update now",
                                       action: #selector(UserActions.ApplicationActions.installUpdate),
                                       keyEquivalent: "")
        menuItem.target = userActions.app
        menuItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        return menuItem
    }
#endif

    private var settingsMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(
            title: "Settings",
            action: #selector(UserActions.WindowActions.showSettings),
            keyEquivalent: ","
        )
        menuItem.target = userActions.windows
        menuItem.setAccessibilityIdentifier("MenuBarCoordinator.MenuItem.settings")
        return menuItem
    }

    private var loginMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(
            title: "Sign in",
            action: #selector(UserActions.WindowActions.showLogin),
            keyEquivalent: ""
        )
        menuItem.target = userActions.windows
        return menuItem
    }

    private var showLogsMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(
            title: "Show Logs",
            action: #selector(UserActions.WindowActions.showLogsWhenNotConnected),
            keyEquivalent: "l"
        )
        menuItem.target = userActions.windows
        return menuItem
    }

    private var bugReportMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(
            title: "Report an Issue...",
            action: #selector(UserActions.LinkActions.reportBug),
            keyEquivalent: "b"
        )
        menuItem.target = userActions.links
        return menuItem
    }

#if HAS_QA_FEATURES
    private var qaSettingsMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(
            title: "QA Settings",
            action: #selector(UserActions.WindowActions.showQASettings),
            keyEquivalent: "a"
        )
        menuItem.target = userActions.windows
        return menuItem
    }

    private var globalProgressVisibilityMenuItem: NSMenuItem {
        let hidden = !UserDefaults.standard.bool(forKey: QASettingsConstants.globalProgressStatusMenuEnabled)
        let label = (hidden ? "Show" : "Hide") + " global progress"
        let menuItem = NSMenuItem(
            title: label,
            action: #selector(UserActions.DebuggingActions.toggleGlobalProgressStatusItem),
            keyEquivalent: "g")
        menuItem.target = userActions.debugging
        return menuItem
    }

    private var performFullResyncMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(
            title: Localization.full_resync_state_description,
            action: #selector(performFullResyncAndOpenWindow),
            keyEquivalent: "r"
        )
        menuItem.target = self
        return menuItem
    }
    
    @objc private func performFullResyncAndOpenWindow() {
        userActions.resync.performFullResync()
        userActions.app.showStatusWindow()
    }

    private var signoutMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(
            title: "Sign out",
            action: #selector(UserActions.AccountActions.userRequestedSignOut),
            keyEquivalent: "s"
        )
        menuItem.target = userActions.account
        return menuItem
    }
#endif

    private var quitAppMenuItem: NSMenuItem {
        let menuItem = NSMenuItem(
            title: "Quit Proton Drive",
            action: #selector(UserActions.ApplicationActions.quitApp),
            keyEquivalent: "q"
        )
        menuItem.target = userActions.app
        return menuItem
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        Log.trace()

        updateMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        Log.trace()

        statusItem.menu = nil
    }

    // MARK: - Activity indicator

    public func showActivityIndicator() {
        Log.trace()
        activityIndicatorEnabled = true
    }
    public func hideActivityIndicator() {
        Log.trace()
        activityIndicatorEnabled = false
    }
}

extension MenuBarCoordinator {
    var menuItemsForTesting: [NSMenuItem]? {
        self.statusItem.menu?.items
    }
}
