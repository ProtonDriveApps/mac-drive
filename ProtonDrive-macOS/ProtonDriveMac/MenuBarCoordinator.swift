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
import Combine
import FileProvider
import PDCore
import PDFileProvider
import ProtonCoreUIFoundations

protocol LoggedInStateReporter {
    var isLoggedIn: Bool { get }
    var isLoggedInPublisher: AnyPublisher<Bool, Never> { get }
}

extension InitialServices: LoggedInStateReporter { }

@objc protocol MenuBarDelegate: AnyObject, AppContentDelegate, NSMenuDelegate {
    func showLogin()
    func showSettings()
    
    #if HAS_QA_FEATURES
    func showQASettings()
    #endif
    
    func quitApp()
    func showLogsInFinder() async throws
    func bugReport()
    func showErrorView()

    func didTapOnMenu(from button: NSButton)

    // Used for SyncActivityMenu
    func pauseSyncing()
    func resumeSyncing()
}

private enum MenuBarUpdateAvailabilityStatus: Equatable {
    case noStatus
    case availableForInstall(version: String)
}

final class MenuBarCoordinator {

    private var syncMonitor: SyncMonitorProtocol?
    private var loggedInStateReporter: LoggedInStateReporter
    private weak var delegate: MenuBarDelegate!
    private let networkStateService: NetworkStateInteractor
    private let syncStateService: SyncStateService
    private let domainOperationsService: DomainOperationsService

    var featureFlags: FeatureFlagsRepository?

    private var statusItem: NSStatusItem!

    #if DEBUG
    private let observationCenter = UserDefaultsObservationCenter(userDefaults: Constants.appGroup.userDefaults,
                                                                  additionalLogging: true)
    #else
    private let observationCenter = UserDefaultsObservationCenter(userDefaults: Constants.appGroup.userDefaults)
    #endif
    #if HAS_BUILTIN_UPDATER
    private let appUpdaterService: AppUpdateServiceProtocol
    #endif

    private var syncedTimeDateFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private var syncActivityMenuItem = NSMenuItem()
    private var updateAvailable: MenuBarUpdateAvailabilityStatus = .noStatus {
        didSet {
            guard updateAvailable != oldValue else { return }
            updateMenu()
        }
    }
    private var syncTimer: Timer?
    private let syncTimerInterval: TimeInterval = 10

    private var errorsCountTitle: String {
        "\(errorsCount) Sync errors"
    }

    private var menuOpenedLifecycleCancellables = Set<AnyCancellable>()
    private var coordinatorLifecycleCancellables = Set<AnyCancellable>()
    
    public var cacheRefreshSyncState: SyncMonitor.SyncState = .synced {
        didSet {
            guard cacheRefreshSyncState != oldValue else { return }
            Log.debug("MenuBarCoordinator \(instanceIdentifier.uuidString) cacheRefreshSyncState changed to \(cacheRefreshSyncState.rawValue)",
                      domain: .syncing)
            updatePresentedSyncState(syncState: cacheRefreshSyncState, pauseState: pauseState)
        }
    }

    // this is the real sync state, as reported by the file extension through `UserDefaults.syncing`
    private var syncState: SyncMonitor.SyncState? {
        didSet {
            guard syncState != oldValue else { return }
            Log.debug("MenuBarCoordinator \(instanceIdentifier.uuidString) syncState changed to \(syncState?.rawValue ?? "nil")",
                      domain: .syncing)
            updatePresentedSyncState(syncState: syncState, pauseState: pauseState)
        }
    }
    // this is the state of pausing. This is user-driven and changes only based on the user's interaction
    private var pauseState: SyncMonitor.PauseState = .active {
        didSet {
            guard pauseState != oldValue else { return }
            Log.debug("MenuBarCoordinator \(instanceIdentifier.uuidString) pauseState changed to \(pauseState.rawValue)",
                      domain: .syncing)
            updateSyncMonitor(pauseState: pauseState, offline: offline)
            updatePresentedSyncState(syncState: syncState, pauseState: pauseState)
            updateMenu()
        }
    }
    // this is the sync state as presented to the user. It's not identicat to real `syncState` because:
    // * if we are paused, we show always `synced`, even if real state is `syncing`
    // * there's a delay introduced between receiving `synced` state and showing `synced` state to the user.
    //   this delay ensures that in case there are multitple sync state changes done one after the other, we are smoothing them out
    private var presentedSyncState: SyncMonitor.SyncState = .synced {
        didSet {
            guard presentedSyncState != oldValue else { return }
            Log.debug("MenuBarCoordinator \(instanceIdentifier.uuidString) presentedSyncState changed to \(presentedSyncState.rawValue)",
                      domain: .syncing)
            updateMenu()
        }
    }

    private var errorsCountSubject: PassthroughSubject<Int, Never>?
    private var syncErrorsCancellable: AnyCancellable?
    private var networkStateCancellable: AnyCancellable?

    private var offline: Bool = false {
        didSet {
            guard offline != oldValue else { return }
            Log.info("MenuBarCoordinator \(instanceIdentifier.uuidString) offline changed to \(offline.description)",
                     domain: .syncing)
            updateSyncMonitor(pauseState: pauseState, offline: offline)
            updateMenu()
        }
    }

    var errorsCount: Int = 0 {
        didSet {
            guard errorsCount != oldValue else { return }
            updateMenu()
        }
    }
    
    var newTrayAppMenuFeatureFlagEnabled: Bool {
        #if HAS_FEATURES_UNDER_DEVELOPMENT
        featureFlags?.isEnabled(flag: .newTrayAppMenuEnabled) == true
        #else
        false
        #endif
    }

    private let instanceIdentifier = UUID()

    #if HAS_BUILTIN_UPDATER
    @MainActor
    init(delegate: MenuBarDelegate,
         loggedInStateReporter: LoggedInStateReporter,
         appUpdaterService: AppUpdateServiceProtocol,
         networkStateService: NetworkStateInteractor,
         syncStateService: SyncStateService,
         domainOperationsService: DomainOperationsService) {
        self.appUpdaterService = appUpdaterService
        self.networkStateService = networkStateService
        self.syncStateService = syncStateService
        self.domainOperationsService = domainOperationsService
        self.loggedInStateReporter = loggedInStateReporter
        self.delegate = delegate
        self.statusItem = self.makeStatusItem()
        Log.info("MenuBarCoordinator init: \(instanceIdentifier.uuidString)", domain: .syncing)
        setupObservations()
    }
    #else
    @MainActor
    init(delegate: MenuBarDelegate, 
         loggedInStateReporter: LoggedInStateReporter,
         networkStateService: NetworkStateInteractor,
         syncStateService: SyncStateService,
         domainOperationsService: DomainOperationsService) {
        self.loggedInStateReporter = loggedInStateReporter
        self.delegate = delegate
        self.networkStateService = networkStateService
        self.syncStateService = syncStateService
        self.domainOperationsService = domainOperationsService
        self.statusItem = self.makeStatusItem()
        Log.info("MenuBarCoordinator init: \(instanceIdentifier.uuidString)", domain: .syncing)
        setupObservations()
    }
    #endif
    
    deinit {
        Log.info("MenuBarCoordinator deinit: \(instanceIdentifier.uuidString)", domain: .syncing)
    }
    
    private func setupObservations() {
        #if HAS_BUILTIN_UPDATER
        
        func menuBarUpdateAvailabilityStatus(from status: UpdateAvailabilityStatus) -> MenuBarUpdateAvailabilityStatus {
            switch status {
            // show no menu bar entry for these
            case .upToDate, .checking, .downloading, .extracting, .errored:
                return MenuBarUpdateAvailabilityStatus.noStatus
            // show menu bar entry
            case .readyToInstall(let version):
                return MenuBarUpdateAvailabilityStatus.availableForInstall(version: version)
            }
        }
        
        updateAvailable = menuBarUpdateAvailabilityStatus(from: appUpdaterService.updateAvailability)
        appUpdaterService.updateAvailabilityPublisher
            .removeDuplicates()
            .map(menuBarUpdateAvailabilityStatus)
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] in
                self.updateAvailable = $0
            }
            .store(in: &coordinatorLifecycleCancellables)
        #endif
        
        observationCenter.addObserver(self, of: \.syncing) { [unowned self] syncing in
            self.syncState = syncing.map { $0 ? SyncMonitor.SyncState.syncing : .synced }
        }
        self.subscribeToLogoutState()
        self.subscribeToNetworkState()
    }
    
    func startSyncMonitoring(eventsProcessor: EventsSystemManager, syncErrorsSubject: PassthroughSubject<Int, Never>?) {
        self.errorsCountSubject = syncErrorsSubject
        self.syncMonitor = SyncMonitor(eventsProcessor: eventsProcessor,
                                       domainOperationsService: domainOperationsService)
        subscribeToSyncErrorUpdates()
    }

    func updateMenu() {
        DispatchQueue.main.async { [unowned self] in
            statusItem.button?.image = menuIconImage()
            guard let menu = statusItem.menu else {
                return
            }
            populateMenu(menu)
        }
    }

    func refreshMenuItemsIfNeeded() {
        DispatchQueue.main.async {
            self.syncActivityMenuItem.title = self.presentedSyncState == .syncing ? "Syncing" : self.titleWhenSynced()
            self.syncActivityMenuItem.image = NSImage(named: self.presentedSyncState == .syncing ? "syncing" : "synced")
        }
    }

    func menuWillOpen(withErrors count: Int) {
        if loggedInStateReporter.isLoggedIn {
            errorsCount = count
            refreshMenuItemsIfNeeded()

            Timer.publish(every: 5.0, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    self?.refreshMenuItemsIfNeeded()
                }
                .store(in: &menuOpenedLifecycleCancellables)
        }
    }

    func menuDidClose() {
        menuOpenedLifecycleCancellables.removeAll()
        statusItem.menu = nil
    }

    func stopMonitoring() {
        syncMonitor = nil
        errorsCountSubject?.send(0)
        pauseState = .active
    }
    
    private func updateSyncMonitor(pauseState: SyncMonitor.PauseState, offline: Bool) {
        self.syncMonitor?.updateState(pauseState, offline: offline)
    }

    private func updatePresentedSyncState(syncState: SyncMonitor.SyncState?, pauseState: SyncMonitor.PauseState) {
        guard pauseState != .paused else {
            // if paused, we always show sync state, regardless of reality
            presentedSyncState = .synced
            return
        }
        
        switch syncState {
        case .syncing:
            if let syncTimer {
                Log.debug("Sync timer invalidated", domain: .syncing)
                syncTimer.invalidate()
            }
            syncTimer = nil
            presentedSyncState = .syncing
        case nil, .synced:
            Log.debug("Sync timer scheduled", domain: .syncing)
            let syncTimer = Timer(timeInterval: syncTimerInterval, repeats: false) { [weak self] timer in
                Log.debug("Sync timer fired", domain: .syncing)
                self?.presentedSyncState = .synced
                self?.syncTimer = nil
            }
            self.syncTimer = syncTimer
            syncTimer.tolerance = syncTimerInterval / 5
            RunLoop.current.add(syncTimer, forMode: .common)
        }
    }

    private func subscribeToSyncErrorUpdates() {
        syncErrorsCancellable = self.errorsCountSubject?
            .sink { [weak self] count in
                Log.debug("Update Sync errors: \(count) ", domain: .syncing)
                self?.errorsCount = count
            }
    }
    
    private func subscribeToLogoutState() {
        loggedInStateReporter.isLoggedInPublisher
            .removeDuplicates()
            .sink { [weak self] isSignedIn in
                // update state only when not signed in
                guard !isSignedIn else { return }
                self?.updateMenu()
            }
            .store(in: &coordinatorLifecycleCancellables)
    }

    private func subscribeToNetworkState() {
        networkStateService.state
            .removeDuplicates()
            .sink { [weak self] state in
                let isOffline = (state == .unreachable)
                self?.offline = isOffline
                let stateMessage = isOffline ? "unreachable" : "reachable"
                Log.info("Network state: \(stateMessage)", domain: .networking)
            }.store(in: &coordinatorLifecycleCancellables)
    }

    @MainActor
    private func makeStatusItem() -> NSStatusItem {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button!.image = menuIconImage()
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.action = #selector(statusBarButtonTapped(_:))
        return statusItem
    }

    /// Priority order for display
    /// 1. Paused
    /// 2. Offline
    /// 3. Syncing
    /// 4. Update available
    /// 5. Error
    /// 6. Synced
    private func menuIconImage() -> NSImage {
        let iconName: String
        var menuBarState: SyncStateService.MenuBarState = .synced
        if !loggedInStateReporter.isLoggedIn {
            iconName = "status-signed-out"
            menuBarState = .signedOut
        } else if pauseState == .paused {
            iconName = "status-paused"
            menuBarState = .paused
        } else if offline {
            iconName = "status-offline"
            menuBarState = .offline
        } else if presentedSyncState == .syncing {
            iconName = "status-syncing"
            menuBarState = .syncing
        } else if case .availableForInstall = updateAvailable {
            iconName = "status-update-available"
            menuBarState = .updateAvailable
        } else if errorsCount > 0 {
            iconName = "status-error"
            menuBarState = .error
        } else {
            iconName = "status-synced"
            menuBarState = .synced
        }
        syncStateService.menuBarState = menuBarState
        syncStateService.syncStatePublisher.send(menuBarState)

        let margin = 2
        let size = Int(NSStatusBar.system.thickness) - margin * 2
        return NSImage(named: iconName)!.resize(newWidth: size, newHeight: size)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        if loggedInStateReporter.isLoggedIn {
            menu.addItem(syncActivityMenuItem)
            self.updateSyncActivityMenuItem()
            if offline {
                menu.addItem(offlineMenuItem)
            }
            if errorsCount > 0 {
                menu.addItem(syncErrorMenuItem)
            }
            
            if !newTrayAppMenuFeatureFlagEnabled {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(eventSyncMenuItem)
            }

            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem.separator())
            menu.addItem(openDriveMenuItem)
            if case .availableForInstall = updateAvailable {
                menu.addItem(NSMenuItem.separator())
                menu.addItem(appUpdateAvailabilityMenuItem)
            }
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
        menu.addItem(qaSettingsMenuItem)
        menu.addItem(NSMenuItem.separator())
        #endif

        menu.addItem(quitAppMenuItem)
    }

    private func updateSyncActivityMenuItem() {
        let title = presentedSyncState == .syncing ? "Syncing" : titleWhenSynced()
        syncActivityMenuItem.title = title
        syncActivityMenuItem.image = NSImage(named: presentedSyncState == .syncing ? "syncing" : "synced")
        syncActivityMenuItem.target = self
        syncActivityMenuItem.action = #selector(self.doNothing)
        let accessibilityIdentifier = presentedSyncState == .syncing ? "MenuBarCoordinator.MenuItem.syncing"
        : "MenuBarCoordinator.MenuItem.synced"
        syncActivityMenuItem.setAccessibilityIdentifier(accessibilityIdentifier)
    }
    
    private var openDriveMenuItem: NSMenuItem {
        let openDriveFolder = NSMenuItem(title: "Open Drive Folder", action: #selector(delegate.openDriveFolder), keyEquivalent: "")
        openDriveFolder.target = delegate
        return openDriveFolder
    }
    
    private var settingsMenuItem: NSMenuItem {
        let showSettings = NSMenuItem(title: "Settings", action: #selector(delegate.showSettings), keyEquivalent: "")
        showSettings.target = delegate
        showSettings.setAccessibilityIdentifier("MenuBarCoordinator.MenuItem.settings")
        return showSettings
    }
    
    private var loginMenuItem: NSMenuItem {
        let showLogin = NSMenuItem(title: "Sign in", action: #selector(delegate.showLogin), keyEquivalent: "")
        showLogin.target = delegate
        return showLogin
    }
    
    private var quitAppMenuItem: NSMenuItem {
        let quitApp = NSMenuItem(title: "Quit", action: #selector(delegate.quitApp), keyEquivalent: "")
        quitApp.target = delegate
        return quitApp
    }

    #if HAS_QA_FEATURES
    private var qaSettingsMenuItem: NSMenuItem {
        let qaSettings = NSMenuItem(title: "QA Settings", action: #selector(delegate.showQASettings), keyEquivalent: "")
        qaSettings.target = delegate
        return qaSettings
    }
    #endif

    private var offlineMenuItem: NSMenuItem {
        let offlineItem = NSMenuItem(title: "Offline", action: #selector(self.doNothing), keyEquivalent: "")
        offlineItem.target = self
        offlineItem.image = NSImage(named: "cloud-slash")
        offlineItem.setAccessibilityIdentifier("MenuBarCoordinator.MenuItem.offline")
        return offlineItem
    }

    private var syncErrorMenuItem: NSMenuItem {
        let errorItem = NSMenuItem(title: "\(errorsCountTitle)", action: #selector(delegate.showErrorView), keyEquivalent: "E")
        errorItem.target = delegate
        errorItem.image = NSImage(named: "cross-circle")
        errorItem.isHidden = !(errorsCount > 0)
        errorItem.setAccessibilityIdentifier("MenuBarCoordinator.MenuItem.syncError")
        return errorItem
    }

    private var eventSyncMenuItem: NSMenuItem {
        let isPaused = pauseState == .paused
        let title = isPaused ? "Resume syncing" : "Pause syncing"
        let selector = isPaused ? #selector(resumeSyncing) : #selector(pauseSyncing)
        let eventSyncItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        eventSyncItem.image = NSImage(named: isPaused ? "resume" : "pause")
        eventSyncItem.target = self
        let accessibilityIdentifier = isPaused ? "MenuBarCoordinator.MenuItem.resumeSyncing"
        : "MenuBarCoordinator.MenuItem.pauseSyncing"
        eventSyncItem.setAccessibilityIdentifier(accessibilityIdentifier)
        return eventSyncItem
    }

    private var showLogsMenuItem: NSMenuItem {
        let showLogItem = NSMenuItem(title: "Show Logs", action: #selector(showLogsWhenNotConnected), keyEquivalent: "")
        showLogItem.target = self
        return showLogItem
    }
    
    private var bugReportMenuItem: NSMenuItem {
        let bugReportItem = NSMenuItem(title: "Report an Issue...", action: #selector(delegate.bugReport), keyEquivalent: "")
        bugReportItem.target = delegate
        return bugReportItem
    }
    
    private var appUpdateAvailabilityMenuItem: NSMenuItem {
        let appUpdateItem = NSMenuItem(title: "Install update now",
                                       action: #selector(userRequestedInstallingUpdate),
                                       keyEquivalent: "")
        appUpdateItem.target = self
        appUpdateItem.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        return appUpdateItem
    }
    
    @objc func showLogsWhenNotConnected() {
        // Just opening
        guard let logsDirectory = try? PDFileManager.getLogsDirectory() else {
            Log.info("No Logs directory created yet", domain: .application)
            return
        }
        let dbDestination = logsDirectory.appendingPathComponent("DB", isDirectory: true)
        let appGroupContainerURL = logsDirectory.deletingLastPathComponent()
        try? PDFileManager.copyDatabases(from: appGroupContainerURL, to: dbDestination)

        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logsDirectory.path)
    }

    @objc func userRequestedInstallingUpdate() {
        #if HAS_BUILTIN_UPDATER
        appUpdaterService.installUpdateIfAvailable()
        #endif
    }

    private func titleWhenSynced() -> String {
        let title = "Synced"
        let recentSyncTitle = "Synced just now"
        guard let dateFromInterval = lastSyncedDate() else {
            return recentSyncTitle
        }
        let secondsDifference = Date().timeIntervalSince(dateFromInterval)

        if secondsDifference < 60 {
            return recentSyncTitle
        }

        let relativeDateString = syncedTimeDateFormatter.localizedString(for: dateFromInterval, relativeTo: Date())

        return "\(title) \(relativeDateString)"
    }

    private func lastSyncedDate() -> Date? {
        let lastSyncedKey = UserDefaults.Key.lastSyncedTimeKey.rawValue
        guard let groupUserDefaults = UserDefaults(suiteName: PDCore.Constants.appGroup),
              groupUserDefaults.double(forKey: lastSyncedKey) > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: groupUserDefaults.double(forKey: lastSyncedKey))
    }

    // MARK: - MenuBar Items Actions

    @objc func pauseSyncing() {
        pauseState = .paused
    }

    @objc func resumeSyncing() {
        pauseState = .active
    }

    @objc func statusBarButtonTapped(_ sender: NSButton) {
        if Constants.isInUITests {
            showOldMenu()
            return
        }

        if newTrayAppMenuFeatureFlagEnabled {
            guard let event = NSApp.currentEvent, let statusButton = statusItem.button else { return }
            if event.type == .leftMouseUp {
                delegate.didTapOnMenu(from: statusButton)
            } else {
                showOldMenu()
            }
        } else {
            showOldMenu()
        }
    }

    private func showOldMenu() {
        if statusItem.menu == nil {
            let menu = NSMenu()
            menu.delegate = delegate
            populateMenu(menu)
            statusItem.menu = menu
        }
        statusItem.button?.performClick(nil)
    }

    // We need this selector if we want to keep UI in non disabled state for non clickable MenuItems
    @objc func doNothing() {}
}
