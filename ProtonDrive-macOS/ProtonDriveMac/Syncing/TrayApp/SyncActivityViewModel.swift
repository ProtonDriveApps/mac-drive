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

import Combine
import PDCore
import AppKit

public enum SyncActivityError: Error {
    case nodeNotFound
    case noCommunicationService
    case noStorage
}

final class SyncActivityViewModel: ObservableObject {

    typealias Update = ReportableSyncItem

    #if HAS_QA_FEATURES
    // swiftlint:disable:next large_tuple
    typealias Actions = (
        pauseSyncing: () -> Void,
        resumeSyncing: () -> Void,
        showSettings: () -> Void,
        showQASettings: () -> Void,
        showLogsInFinder: () -> Void,
        reportBug: () -> Void,
        showErrorWindow: () -> Void,
        openDriveFolder: () -> Void,
        viewOnline: () -> Void,
        addStorage: () -> Void,
        quitApp: () -> Void
    )
    #else
    // swiftlint:disable:next large_tuple
    typealias Actions = (
        pauseSyncing: () -> Void,
        resumeSyncing: () -> Void,
        showSettings: () -> Void,
        showLogsInFinder: () -> Void,
        reportBug: () -> Void,
        showErrorWindow: () -> Void,
        openDriveFolder: () -> Void,
        viewOnline: () -> Void,
        addStorage: () -> Void,
        quitApp: () -> Void
    )
    #endif

    typealias SignInAction = () -> Void

    let signInAction: SignInAction?

    private let getMoreStorageURL: URL = URL(string: "https://account.proton.me/drive/dashboard")!

    private let driveURL: URL = URL(string: "https://drive.proton.me")!

    enum NotificationState: Int, Equatable {
        case error
        case update
        case none
    }

    enum SyncOverallStatus: Int, Sendable, Equatable {
        case paused
        case offline
        case errored
        case inProgress
        case synced
    }

    private let metadataMonitor: MetadataMonitor?
    private var delegate: MenuBarDelegate?

    var initials: String? { accountInfo?.displayName.initials() }
    var displayName: String? { accountInfo?.displayName }
    var emailAddress: String? { accountInfo?.email }

    let itemBaseURL: URL?
    private let sessionVault: SessionVault
    private let communicationService: CoreDataCommunicationService<SyncItem>?
    #if HAS_BUILTIN_UPDATER
    private var appUpdateService: any AppUpdateServiceProtocol
    @Published var updateAvailability: UpdateAvailabilityStatus
    #endif
    private let syncStateService: SyncStateService

    private let updates: AsyncStream<EntityWithChangeType<SyncItem>>?

    private var updatesTask: Task<(), Never>?

    @Published var accountInfo: AccountInfo?

    @Published var items: [ReportableSyncItem] = [] {
        didSet {
            self.sortedItems = Array(items
                .prefix(30)
                .sorted(by: syncItemSortFunction)
            )
        }
    }

    let syncingPausedSubject = CurrentValueSubject<Bool, Never>(false)

    @Published var sortedItems: [ReportableSyncItem] = []

    @Published var notificationState: NotificationState = .error

    @Published var overallState: SyncOverallStatus = .synced {
        didSet {
            self.syncingPausedSubject.send(overallState == .paused)
        }
    }

    @Published var erroredItemsCount: Int = 0

    @Published var syncedTitle: String

    private var cancellables: Set<AnyCancellable> = []

    #if HAS_BUILTIN_UPDATER
    init(metadataMonitor: MetadataMonitor?,
         sessionVault: SessionVault,
         communicationService: CoreDataCommunicationService<SyncItem>?,
         appUpdateService: AppUpdateServiceProtocol,
         syncStateService: SyncStateService,
         delegate: MenuBarDelegate? = nil,
         itemBaseURL: URL?,
         signInAction: SignInAction?) {
        self.metadataMonitor = metadataMonitor
        self.communicationService = communicationService
        self.appUpdateService = appUpdateService
        self.updateAvailability = appUpdateService.updateAvailability
        self.syncStateService = syncStateService
        self.syncedTitle = syncStateService.syncedTitle
        self.updates = communicationService?.updates
        self.sessionVault = sessionVault
        self.accountInfo = sessionVault.getAccountInfo()
        self.delegate = delegate
        self.itemBaseURL = itemBaseURL
        self.signInAction = signInAction
        observeUpdates()
        subscribeToNotifications()
    }
    #else
    init(metadataMonitor: MetadataMonitor?,
         sessionVault: SessionVault,
         communicationService: CoreDataCommunicationService<SyncItem>?,
         syncStateService: SyncStateService,
         delegate: MenuBarDelegate? = nil,
         itemBaseURL: URL?,
         signInAction: SignInAction?) {
        self.metadataMonitor = metadataMonitor
        self.communicationService = communicationService
        self.syncStateService = syncStateService
        self.syncedTitle = syncStateService.syncedTitle
        self.updates = communicationService?.updates
        self.sessionVault = sessionVault
        self.accountInfo = sessionVault.getAccountInfo()
        self.delegate = delegate
        self.itemBaseURL = itemBaseURL
        self.signInAction = signInAction
        observeUpdates()
        subscribeToNotifications()
    }
    #endif

    deinit {
        updatesTask?.cancel()
    }
 
    private func subscribeToNotifications() {
        sessionVault.accountInfoPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newAccountInfo in
                self?.accountInfo = newAccountInfo
            }
            .store(in: &cancellables)

        #if HAS_BUILTIN_UPDATER
        appUpdateService.updateAvailabilityPublisher
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] in
                self.updateAvailability = $0
                switch self.updateAvailability {
                case .readyToInstall:
                    self.notificationState = .update
                default:
                    self.updateNotificationState(errorCount: self.erroredItemsCount)
                }
            }
            .store(in: &cancellables)
        #endif

        /// Priority order for display
        /// 1. Paused
        /// 2. Offline
        /// 3. Syncing
        /// 4. Update available
        /// 5. Error
        /// 6. Synced
        syncStateService.syncStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [unowned self] syncState in
                self.updateOverallState(syncState)
            }
            .store(in: &cancellables)

        syncStateService.syncedTitlePublisher
            .assign(to: &$syncedTitle)
    }

    func updateOverallState(_ syncState: SyncStateService.MenuBarState) {
        DispatchQueue.main.async {
            guard syncState != .signedOut else {
                return
            }
            if syncState == .paused {
                self.overallState = .paused
            } else if syncState == .offline {
                self.overallState = .offline
            } else if syncState == .syncing {
                self.overallState = .inProgress
            } else if syncState == .error {
                self.overallState = .errored
            } else {
                self.overallState = .synced
            }
            if self.overallState == .synced {
                self.syncStateService.startTimer()
            }
        }
    }

    private func syncItemSortFunction(lhs: ReportableSyncItem, rhs: ReportableSyncItem) -> Bool {
        if lhs.state == .inProgress && rhs.state != .inProgress {
            return true
        } else if lhs.state != .inProgress && rhs.state == .inProgress {
            return false
        } else {
            return lhs.modificationTime > rhs.modificationTime
        }
    }

    private func observeUpdates() {
        guard let updates else {
            return
        }

        $items
            .receive(on: DispatchQueue.main)
            .map { syncItems in
                syncItems.filter { $0.state == .errored }.count
            }
            .removeDuplicates()
            .sink { [unowned self] newCount in
                if self.erroredItemsCount != newCount {
                    self.erroredItemsCount = newCount
                    self.updateNotificationState(errorCount: newCount)
                }
            }
            .store(in: &cancellables)

        updatesTask = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled else { return }
                switch update {
                case .delete(let objectIdentifier):
                    await MainActor.run { [weak self] in
                        self?.items.removeAll(where: { $0.objectIdentifier == objectIdentifier })
                    }

                case .insert(let syncItem):
                    guard let reportableSyncItem = await self?.reportableItem(from: syncItem) else { continue }
                    await MainActor.run { [weak self] in
                        self?.items.insert(reportableSyncItem, at: 0)
                    }

                case .update(let syncItem):
                    guard
                        let reportableSyncItem = await self?.reportableItem(from: syncItem),
                        let index = self?.items.firstIndex(where: { $0.objectIdentifier == syncItem.objectIdentifier })
                    else { continue }
                    await MainActor.run { [weak self] in
                        self?.items[index] = reportableSyncItem
                    }

                @unknown default:
                    Log.error("Unknown case for NSPersistentHistoryChangeType", domain: .ipc)
                }
            }
        }
    }

    func clearStorage() {
        Task {
            await metadataMonitor?.syncStorage?.clearUp()
        }
    }

    private func clearActiveSyncingItemsOnPause() {
        if let context = metadataMonitor?.syncStorage?.mainContext {
            Task {
                do {
                    try await metadataMonitor?.syncStorage?.removeSyncingDownloadedItems(in: context)
                } catch {
                    Log.info("Could not remove syncing items", domain: .storage)
                }
            }
        }
    }

    private func updateNotificationState(errorCount: Int) {
        if errorCount > 0 {
            self.notificationState = .error
        } else {
            switch updateAvailability {
            case .readyToInstall:
                self.notificationState = .update
            default:
                self.notificationState = .none
            }
        }
    }

    private func reportableItem(from managedItem: SyncItem) async -> ReportableSyncItem? {
        await communicationService?.moc.perform {
            guard managedItem.filename != nil else {
                return nil
            }
            return ReportableSyncItem(item: managedItem)
        }
    }

    private func node(with id: String) async -> Node? {
        guard let metadataStorage = metadataMonitor?.storage else {
            return nil
        }

        let context = metadataStorage.backgroundContext
        return await context.perform {
            let nodes: [Node] = metadataStorage.existing(with: [id], in: context)
            return nodes.first
        }
    }
}

extension SyncActivityViewModel {

    var headerViewActions: HeaderView.Actions {
        #if HAS_QA_FEATURES
        .init(
            pauseSyncing: self.actions.pauseSyncing,
            resumeSyncing: self.actions.resumeSyncing,
            showSettings: self.actions.showSettings,
            showQASettings: self.actions.showQASettings,
            showLogsInFinder: self.actions.showLogsInFinder,
            reportBug: self.actions.reportBug,
            quitApp: self.actions.quitApp
        )
        #else
        .init(
            pauseSyncing: self.actions.pauseSyncing,
            resumeSyncing: self.actions.resumeSyncing,
            showSettings: self.actions.showSettings,
            showLogsInFinder: self.actions.showLogsInFinder,
            reportBug: self.actions.reportBug,
            quitApp: self.actions.quitApp
        )
        #endif
    }

    var toolbarActions: ToolbarView.Actions {
        .init(
            openDriveFolder: self.actions.openDriveFolder,
            viewOnline: self.actions.viewOnline,
            addStorage: self.actions.addStorage
        )
    }

    #if HAS_BUILTIN_UPDATER
    func installUpdate() {
        appUpdateService.installUpdateIfAvailable()
    }
    #endif

    func changeSyncingStatus() {
        if overallState != .paused {
            headerViewActions.pauseSyncing()
        } else {
            headerViewActions.resumeSyncing()
        }
    }

    var actions: SyncActivityViewModel.Actions {
        #if HAS_QA_FEATURES
        (
            pauseSyncing: {
                self.delegate?.pauseSyncing()
                self.clearActiveSyncingItemsOnPause()
            },
            resumeSyncing: { self.delegate?.resumeSyncing() },
            showSettings: { self.delegate?.showSettings() },
            showQASettings: { self.delegate?.showQASettings() },
            showLogsInFinder: { Task { try? await self.delegate?.showLogsInFinder() } },
            reportBug: { self.delegate?.bugReport() },
            showErrorWindow: { self.delegate?.showErrorView() },
            openDriveFolder: { self.delegate?.openDriveFolder() },
            viewOnline: { self.viewOnline() },
            addStorage: { self.getMoreStorage() },
            quitApp: { self.delegate?.quitApp() }
        )
        #else
        (
            pauseSyncing: {
                self.delegate?.pauseSyncing()
                self.clearActiveSyncingItemsOnPause()
            },
            resumeSyncing: { self.delegate?.resumeSyncing() },
            showSettings: { self.delegate?.showSettings() },
            showLogsInFinder: { Task { try? await self.delegate?.showLogsInFinder() } },
            reportBug: { self.delegate?.bugReport() },
            showErrorWindow: { self.delegate?.showErrorView() },
            openDriveFolder: { self.delegate?.openDriveFolder() },
            viewOnline: { self.viewOnline() },
            addStorage: { self.getMoreStorage() },
            quitApp: { self.delegate?.quitApp() }
        )
        #endif
    }

    func getMoreStorage() {
        open(url: getMoreStorageURL)
    }

    func viewOnline() {
        open(url: driveURL)
    }

    private func open(url: URL) {
        _ = NSWorkspace.shared.open(url)
    }
}
