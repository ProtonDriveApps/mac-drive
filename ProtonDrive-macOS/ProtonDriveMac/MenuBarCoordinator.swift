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
import PDLocalization

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
    // Debug only code to show the current download/upload state in the menu bar.
    // This is independant from the code that shows the real state in statusItem's menu.
    var progressStatusItem: NSStatusItem!
    var showHideProgressStatusMenuItem: NSMenuItem?
    let hideProgressStatusItemDefaultsKey = "DEBUG_hideProgressStatusItem"

    @objc
    private func toggleProgressStatusItemShown() {
        let hidden = !UserDefaults.standard.bool(forKey: hideProgressStatusItemDefaultsKey)
        UserDefaults.standard.set(hidden, forKey: hideProgressStatusItemDefaultsKey)
        showHideProgressStatusMenuItem?.title = hidden ? "Show" : "Hide"
        if hidden {
            updateProgressStatusItem(downloadProgress: nil, uploadProgress: nil)
        }
        // Note - We don't update when reshowing, we have to wait until next progress update as we don't have access
        // to the global progresses from here.
    }
    
    internal func updateProgressStatusItem(downloadProgress: Progress?, uploadProgress: Progress?)
    {
        var accumulated = ""
        if !UserDefaults.standard.bool(forKey: hideProgressStatusItemDefaultsKey) {
            for progress in [downloadProgress, uploadProgress].compactMap({ $0 }) {
                let text: String
                let isDownload = progress == downloadProgress
                let direction = isDownload ? "⬇️" : "⬆️"
                if progress.isFinished {
                    text = "\(direction) Not Busy"
                } else {
                    let fileTotalCount = progress.fileTotalCount ?? 0
                    let currentFileIndex = min(fileTotalCount, 1 + (progress.fileCompletedCount ?? 0))
                    let additionalDescription = progress.localizedAdditionalDescription ?? ""
                    let percent = 100 * progress.fractionCompleted
                    if fileTotalCount == 0, additionalDescription.isEmpty {
                        text = "\(direction) Confused??"
                    } else {
                        let countInfo = fileTotalCount == 1 ? "1 file"
                        : "\(currentFileIndex) of \(fileTotalCount) files"
                        text = "\(direction) \(countInfo): \(additionalDescription) \(String(format: "(%.2f%%)", percent))"
                    }
                }
                
                if !accumulated.isEmpty {
                    accumulated.append(" | ")
                }
                accumulated.append(text)
            }
        }
        
        // If we are hidden (or end up with an empty string), we use a space as otherwise our status item ends up
        // unclickable with zero width so we can't show it again.
        progressStatusItem.button?.title = accumulated.isEmpty ? " " : accumulated
        progressStatusItem.button?.sizeToFit()
    }
    #endif

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
    private let globalProgressMenuItem1: NSMenuItem
    private let globalProgressMenuItem2: NSMenuItem
    private let globalProgressMenuItem3: NSMenuItem
    private let globalProgressMenuItems: [NSMenuItem]
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
    // this is the sync state as presented to the user. It's not identical to real `syncState` because:
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
        self.globalProgressMenuItem1 = NSMenuItem()
        self.globalProgressMenuItem2 = NSMenuItem()
        self.globalProgressMenuItem3 = NSMenuItem()
        self.globalProgressMenuItems = [globalProgressMenuItem1, globalProgressMenuItem2, globalProgressMenuItem3]

        self.globalProgressMenuItems.forEach { $0.title = "" }
        self.globalProgressMenuItems.forEach { $0.isHidden = true }
        self.globalProgressMenuItems.forEach { $0.action = #selector(self.doNothing) }

        self.globalProgressMenuItem1.image = NSImage(named: "syncing")

        self.appUpdaterService = appUpdaterService
        self.networkStateService = networkStateService
        self.syncStateService = syncStateService
        self.domainOperationsService = domainOperationsService
        self.loggedInStateReporter = loggedInStateReporter
        self.delegate = delegate
        self.statusItem = self.makeStatusItem()
        
        #if DEBUG
        self.progressStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.progressStatusItem.button?.font = NSFont.labelFont(ofSize: NSFont.labelFontSize)
        self.progressStatusItem.menu = NSMenu()
        let hidden = UserDefaults.standard.bool(forKey: hideProgressStatusItemDefaultsKey)
        self.showHideProgressStatusMenuItem = self.progressStatusItem.menu?.addItem(withTitle: hidden ? "Show" : "Hide", action: #selector(toggleProgressStatusItemShown), keyEquivalent: "")
        self.showHideProgressStatusMenuItem?.target = self
        
        #endif
        
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
            if presentedSyncState == .synced {
                // Force the global progress items to disappear no, regardless of their true state.
                globalSyncStatusChanged(downloadProgress: nil, uploadProgress: nil)
            }
            
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
    
    func globalSyncStatusChanged(downloadProgress: Progress?, uploadProgress: Progress?) {
        #if DEBUG
        updateProgressStatusItem(downloadProgress: downloadProgress, uploadProgress: uploadProgress)
        #endif
        
        struct GlobalSyncState {
            let totalFileCount: Int
            let completedFileCount: Int
            let fractionCompleted: Double
            let totalByteCount: Int64
            let completedByteCount: Int64
            /// This is the '7' in "7 of 33 files" part of the text and indicates what file its currently doing, not how many completed files there are.
            let currentFileIndex: Int
            
            init?(progress: Progress?) {
                guard let progress,
                      !progress.isFinished,
                      progress.fileTotalCount ?? 0 != 0 else {
                    return nil
                }
                
                totalFileCount = progress.fileTotalCount ?? 0
                guard totalFileCount != 0 else { return nil }
                completedFileCount = progress.fileCompletedCount ?? 0
                currentFileIndex = completedFileCount + 1
                totalByteCount = progress.totalUnitCount
                completedByteCount = progress.completedUnitCount
                fractionCompleted = progress.fractionCompleted
            }
            
            init(byMerging a: GlobalSyncState, with b: GlobalSyncState) {
                totalFileCount = a.totalFileCount + b.totalFileCount
                completedFileCount = a.completedFileCount + b.completedFileCount
                currentFileIndex = a.currentFileIndex + b.currentFileIndex
                totalByteCount = a.totalByteCount + b.totalByteCount
                completedByteCount = a.completedByteCount + b.completedByteCount
                fractionCompleted = Double(completedByteCount) / Double(totalByteCount)
            }
        }
        
        let downloadState = GlobalSyncState(progress: downloadProgress)
        let uploadState = GlobalSyncState(progress: uploadProgress)
        
        let actualState: GlobalSyncState?
        var overview = ""
        
        if presentedSyncState == .synced {
            if downloadState != nil || uploadState != nil {
                Log.debug("Not showing available global progress as presentedSyncState says it is synced", domain: .syncing)
            }
            actualState = nil
        } else {
            switch (downloadState, uploadState) {
            case (nil, nil):
                actualState = nil
                overview = ""
            case(let dl, nil):
                actualState = dl
                overview = "Downloading"
            case (nil, let ul):
                actualState = ul
                overview = "Uploading"
            case (let dl, let ul):
                actualState = GlobalSyncState(byMerging: dl!, with: ul!)
                overview = "Syncing"
            }
        }

        var normalString: NSMutableAttributedString?

        // Don't show progress for very small syncs (as these can be enumerations)
        if let actualState, actualState.totalByteCount > 100 {
            let overviewAttributes = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 0, weight: .bold),
                                      NSAttributedString.Key.foregroundColor: NSColor.selectedMenuItemTextColor]
            let subTextAttributes = [NSAttributedString.Key.font: NSFont.menuFont(ofSize: 0),
                                     NSAttributedString.Key.foregroundColor: NSColor.secondaryLabelColor]

            var percentText: String
            let percentFormat = "%.0f%%"
            percentText = String(format: percentFormat, actualState.fractionCompleted * 100)
            if actualState.fractionCompleted < 1, percentText.starts(with: "100") {
                // We don't want to show 100% unless we really are at the end.
                percentText = "99%"
            }
            
            overview += " \(percentText)"
            normalString = NSMutableAttributedString(string: overview, attributes: overviewAttributes)

            let done = Measurement(value: Double(actualState.completedByteCount), unit: UnitInformationStorage.bytes)
            let toDo = Measurement(value: Double(actualState.totalByteCount), unit: UnitInformationStorage.bytes)
            
            let byteCountText: String
            let doneBytesText = done.formatted(.byteCount(style: .file, allowedUnits: .all, spellsOutZero: true))
            let toDoBytestext = toDo.formatted(.byteCount(style: .file, allowedUnits: .all, spellsOutZero: true))
            byteCountText = "      \(doneBytesText) of \(toDoBytestext)"

            let line2 = NSAttributedString(string: byteCountText, attributes: subTextAttributes)
            globalProgressMenuItem2.title = line2.string
            globalProgressMenuItem2.attributedTitle = line2

            let countInfo = actualState.totalFileCount == 1
            ? "\(NumberFormatter.localizedString(from: 1, number: .decimal)) file" // for a single file it makes no sense to do "x of y" files
            : "\(NumberFormatter.localizedString(from: actualState.currentFileIndex as NSNumber, number: .decimal)) of \(NumberFormatter.localizedString(from: actualState.totalFileCount as NSNumber, number: .decimal)) files"

            let countText = "      \(countInfo)"
            let line3 = NSAttributedString(string: countText, attributes: subTextAttributes)
            globalProgressMenuItem3.title = line3.string
            globalProgressMenuItem3.attributedTitle = line3
        }

        let wasShowingStatus = !globalProgressMenuItem1.title.isEmpty

        globalProgressMenuItem1.title = normalString?.string ?? ""
        globalProgressMenuItem1.attributedTitle = normalString
        globalProgressMenuItems.forEach { $0.target = self }
        globalProgressMenuItems.forEach { $0.isHidden = normalString == nil }

        syncActivityMenuItem.isHidden = !globalProgressMenuItem1.isHidden

        #if DEBUG
        // Temporarily set to true to show all items, regardless of their preferred state.
        // Helpful if you think the progress items are not in tune with what syncActivityMenuItem would show
        let alwaysShowAllItems = false
        if alwaysShowAllItems {
            globalProgressMenuItems.forEach { $0.isHidden = false }
            syncActivityMenuItem.isHidden = false
        }
        #endif
        
        if wasShowingStatus, globalProgressMenuItem1.title.isEmpty, let menu = statusItem.menu {
            // If we were previously showing global status, but now we are not, then we have to repopulate
            // the menu immediately to ensure that if the user is holding down option to see alternate status
            // and the menu is being displayed across the transition they won't see artifacts in the menu.
            populateMenu(menu)
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
        statusItem.button?.setAccessibilityIdentifier("Proton Drive")
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
            globalProgressMenuItems.forEach { menu.addItem($0) }

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
        if presentedSyncState == .syncing {
            let attributes = [NSAttributedString.Key.font: NSFont.systemFont(ofSize: 0, weight: .bold),
                              NSAttributedString.Key.foregroundColor: NSColor.selectedMenuItemTextColor]
            let attributedTitle = NSAttributedString(string: title, attributes: attributes)
            syncActivityMenuItem.attributedTitle = attributedTitle
        } else {
            syncActivityMenuItem.attributedTitle = nil
        }

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
        let quitApp = NSMenuItem(title: "Quit Proton Drive", action: #selector(delegate.quitApp), keyEquivalent: "")
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
        let errorItem = NSMenuItem(title: "\(errorsCountTitle)", action: #selector(delegate.showErrorView), keyEquivalent: "")
        errorItem.target = delegate
        errorItem.image = NSImage(named: "cross-circle")
        errorItem.isHidden = !(errorsCount > 0)
        errorItem.setAccessibilityIdentifier("MenuBarCoordinator.MenuItem.syncError")
        return errorItem
    }

    private var eventSyncMenuItem: NSMenuItem {
        let isPaused = pauseState == .paused
        let title = isPaused ? "Resume Syncing" : "Pause Syncing"
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
