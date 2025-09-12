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
import SwiftUI
import PDLocalization

/// Encapsulates the state of the entire app, driving the UI by publishing updates.
class ApplicationState: ObservableObject {
    /// State of the NotificationView (cases are listed in order of priority)
    enum NotificationState: CustomStringConvertible {
        case error(Int)
        case update
        case resyncFinished
        case none

        var description: String {
            switch self {
            case .error(let count): "Errors (\(count)"
            case .update: "Update"
            case .resyncFinished: "Resync finished"
            case .none: "None"
            }
        }
    }
    
    enum FullResyncState: CustomStringConvertible, Equatable {
        case idle
        case inProgress(Int)
        case enumerating
        case completed(hasFileProviderResponded: Bool?)
        case errored(String)
        
        var isHappening: Bool {
            switch self {
            case .idle, .completed: false
            case .inProgress, .enumerating, .errored: true
            }
        }

        /// Displayed in SyncStateView
        var description: String {
            switch self {
            case .idle: 
                "Idle"
            case .inProgress: 
                "Full resync in progress: downloading data..."
            case .enumerating:
                "Full resync in progress: refreshing directories..."
            case .completed(let hasFileProviderResponded):
#if HAS_QA_FEATURES
                if let hasFileProviderResponded {
                    hasFileProviderResponded ? "Full resync completed" : "Full resync completed (File provider has not responded)"
                } else {
                    "Full resync completed"
                }
#else
                "Full resync completed"
#endif
            case .errored(let message):
                "Full resync error: \(message)"
            }
        }
    }

#if DEBUG
    /// How many times has this been instantiated.
    private static var counter = 0
#endif

    init() {
#if DEBUG && !canImport(XCTest)
        Self.counter += 1
        // Make sure this is only instantiated once.
        assert(Self.counter == 1)
#endif

        $items
            .throttle(for: .seconds(throttlingInterval), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] value in
                self?.throttledItems = value
            }
            .store(in: &cancellables)
    }

    // MARK: General state

    @Published private(set) var accountInfo: AccountInfo?
    @Published private(set) var userInfo: UserInfo?
    @Published private(set) var canGetMoreStorage = true
    @Published private(set) var isOffline = false
    @Published private(set) var isUpdateAvailable = false
    /// Percentage of launch sequence that has been completed
    @Published private(set) var launchCompletion = 0

    // MARK: Sync state

    /// Updated whenever anything changes
    @Published var items: [ReportableSyncItem] = []
    var erroredItems: [ReportableSyncItem] {
        items.filter { $0.state == .errored }
    }

    /// How often should the list of items be refreshed
    private let throttlingInterval: TimeInterval = 1

    /// Updated whenever `items` change, but no more often than once every `throttlingInterval`.
    @Published private(set) var throttledItems: [ReportableSyncItem] = []

    private var cancellables = Set<AnyCancellable>()

    @Published var isSyncing = false
    @Published var isEnumerating = false
    @Published var isPaused = false
    @Published var isResuming = false
    @Published var fullResyncState: FullResyncState = .idle {
        didSet {
            Log.trace("Resync did set fullResyncState to \(fullResyncState)")
        }
    }

    @Published var lastSyncTime: TimeInterval?
    @Published var formattedTimeSinceLastSync: String = ApplicationSyncStatus.synced.displayLabel

    @Published var totalFilesLeftToSync: Int = 0
    @Published var errorCount: Int = 0
    @Published var itemEnumerationProgress: String = ""

    @Published var deleteCount = 0

    @Published var globalSyncStateDescription: String?
//    private var fullResyncStateDescription: String = "Full resync"

    // MARK: Computed

    var overallStatus: ApplicationSyncStatus {
        if launchCompletion < 100 {
            return .launching
        }
        if fullResyncState.isHappening {
            return .fullResyncInProgress
        }
        if accountInfo == nil {
            return .signedOut
        }
        if isPaused {
            return .paused
        }
        if isOffline {
            return .offline
        }
        if isSyncing && !fullResyncState.isHappening {
            return .syncing
        }
        if totalFilesLeftToSync > 0 {
            // Sometimes isSyncing is false because there are no files syncing at that moment, but there are still files left to sync -
            // so we return .syncing to avoid intermittent flashes of "Synced just now" in the middle of syncing.
            return .syncing
        }
        if isEnumerating || (isResuming && !isSyncing) {
            return .enumerating(itemEnumerationProgress)
        }
        if isUpdateAvailable {
            return .updateAvailable
        }
        if errorCount > 0 {
            return .errored(errorCount)
        }
        return .synced
    }

    func displayName(for status: ApplicationSyncStatus) -> String {
        switch status {
        case .synced:
            return formattedTimeSinceLastSync
        case .syncing where globalSyncStateDescription?.isEmpty == false:
            return globalSyncStateDescription ?? self.overallStatus.displayLabel
        case .fullResyncInProgress, .fullResyncCompleted:
            return fullResyncState.description
        default:
            return status.displayLabel
        }
    }

    var notificationState: NotificationState {
        if case .completed = fullResyncState {
            return .resyncFinished
        }
        if fullResyncState.isHappening {
            return .none
        }

        if isUpdateAvailable {
            return .update
        } else {
            if errorCount > 0 {
                return .error(errorCount)
            } else {
                return .none
            }
        }
    }

    var isLoggedIn: Bool {
        accountInfo != nil
    }

    var isLaunching: Bool {
        launchCompletion < 100
    }

    // MARK: - Setters

    func setLaunchCompletion(_ percentage: Int) {
        self.launchCompletion = percentage
    }

    func setAccountInfo(_ accountInfo: AccountInfo?) {
        self.accountInfo = accountInfo
    }

    func setUserInfo(_ userInfo: UserInfo?) {
        self.userInfo = userInfo
    }

    func setOffline(_ isOffline: Bool) {
        self.isOffline = isOffline
    }

    func setUpdateAvailable(_ isUpdateAvailable: Bool) {
        self.isUpdateAvailable = isUpdateAvailable
    }

    func setCanGetMoreStorage(_ canGetMoreStorage: Bool) {
        self.canGetMoreStorage = canGetMoreStorage
    }

    deinit {
        Log.trace()
    }
}

// MARK: - Extensions

extension ApplicationState: CustomDebugStringConvertible {
    struct Property: Equatable, Hashable, CustomStringConvertible {
        let name: String
        let value: String
        init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
        var description: String {
            "\(name): \(value)"
        }
    }
    var properties: [Property] {
        return [
            Property("overallStatus", self.overallStatus.displayLabel),
            Property("overallStatusLabel", self.displayName(for: self.overallStatus)),
            Property("launchCompletion", self.launchCompletion.description),
            Property("accountInfo", self.accountInfo?.displayName ?? "logged out"),
            Property("isLoggedIn", self.isLoggedIn.description),
            Property("lastSyncTime", self.lastSyncTime?.description ?? "n/a"),
            Property("timeSinceSync", self.formattedTimeSinceLastSync),
            Property("itemCount", self.items.count.description),
            Property("totalFilesLeftToSync", self.totalFilesLeftToSync.description),
            Property("errorCount", self.errorCount.description),
            Property("isSyncing", self.isSyncing.description),
            Property("isPaused", self.isPaused.description),
            Property("isResuming", self.isResuming.description),
            Property("isOffline", self.isOffline.description),
            Property("isEnumerating", self.isEnumerating.description),
            Property("itemEnumerationProgress", itemEnumerationProgress),
            Property("isUpdateAvailable", self.isUpdateAvailable.description),
            Property("notificationState", notificationState.description),
            Property("userInfo.usedSpace", userInfo?.usedSpace.description ?? "n/a"),
            Property("userInfo.maxSpace", userInfo?.maxSpace.description ?? "n/a"),
            Property("canGetMoreStorage", canGetMoreStorage.description),
            Property("fullResyncState.description", fullResyncState.description),
            Property("deleteCount", deleteCount.description),
            Property("globalSyncStateDescription", globalSyncStateDescription ?? self.overallStatus.displayLabel),
        ]
    }

    func diff(against otherState: ApplicationState) -> [Property] {
        return Array(Set(self.properties).symmetricDifference(Set(otherState.properties)))
    }

    var debugDescription: String {
        if let jsonData = try? JSONSerialization.data(
            withJSONObject: properties.map { "\($0.name): \($0.value)"
            },
            options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        }

        return "{}" // Return an empty JSON object if serialization fails
    }
}

extension ApplicationState: Equatable {
    static func == (lhs: ApplicationState, rhs: ApplicationState) -> Bool {
        lhs.properties == rhs.properties
    }
}

// MARK: - Mocks

#if HAS_QA_FEATURES
extension ApplicationState {
    static var mockAccountInfo: AccountInfo {
        AccountInfo(
            userIdentifier: "",
            email: "username@example.com",
            displayName: "Alice Smith",
            accountRecovery: nil
        )
    }

    static func mock(
        loggedIn: Bool = true,
        isSyncing: Bool = false,
        isPaused: Bool = false,
        isUpdateAvailable: Bool = false,
        isOffline: Bool = false,
        isLaunching: Bool = false,
        secondsAgo: Int = 0,
        canGetMoreStorage: Bool = true,
        totalFilesLeftToSync: Int? = nil,
        items: [ReportableSyncItem] = [],
        errorCount: Int = 0
    ) -> ApplicationState {
        let state = ApplicationState()
        if loggedIn {
            state.accountInfo = mockAccountInfo
        }
        state.isSyncing = isSyncing
        state.isPaused = isPaused
        state.isUpdateAvailable = isUpdateAvailable
        state.isOffline = isOffline
        state.launchCompletion = isLaunching ? 50 : 100

        if secondsAgo > 0 {
            state.formattedTimeSinceLastSync = "Synced \(secondsAgo)s ago"
        }
        state.canGetMoreStorage = canGetMoreStorage

        state.items = items
        state.errorCount = items.filter { if case .errored = $0.state { true } else { false } }.count
        if let totalFilesLeftToSync, totalFilesLeftToSync > items.count {
            state.totalFilesLeftToSync = totalFilesLeftToSync
        } else {
            state.totalFilesLeftToSync = items.count
        }

        return state
    }

    static var mockWithErrorItems: ApplicationState {
        let mock = mock()
        mock.items = mockItems
        return mock
    }

    static var mockItems: [ReportableSyncItem] {
        [
            ReportableSyncItem(
                id: "id1",
                modificationTime: Date(),
                filename: "IMG_0042-19.jpg",
                location: "Test/IMG_0042-19.jpg",
                mimeType: "image/jpeg",
                fileSize: 1048632,
                operation: .create,
                state: .inProgress,
                progress: 70,
                errorDescription: nil
            ),
            ReportableSyncItem(
                id: "id2",
                modificationTime: Date(),
                filename: "Folder A",
                location: "Test/Folder A",
                mimeType: nil,
                fileSize: nil,
                operation: .create,
                state: .finished,
                progress: 100,
                errorDescription: nil
            ),
            ReportableSyncItem(
                id: "id3",
                modificationTime: Date(),
                filename: "Document.pdf",
                location: "Folder B/Document.pdf",
                mimeType: "application/pdf",
                fileSize: 116921,
                operation: .update,
                state: .errored,
                progress: 0,
                errorDescription: "Could not modify error reason"
            )
        ]
    }

    static var mockErroredState = FileProviderOperation.allCases.map { operation in
        SyncItemState.allCases.map { syncState in
            ReportableSyncItem(
                id: UUID().uuidString,
                modificationTime: Date(),
                filename: "IMG_0042-19.jpg",
                location: "/path/to/file",
                mimeType: "image/jpeg",
                fileSize: 1339346742,
                operation: operation,
                state: syncState,
                progress: 73,
                errorDescription: "An error's localized description (\(syncState), \(operation))"
            )
        }
    }.reduce([], +)
}
#endif
