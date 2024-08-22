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

import Foundation
import Combine
import PDCore

class SyncStateService {

    enum MenuBarState: Sendable {
        case paused
        case offline
        case syncing
        case error
        case updateAvailable
        case synced
        case signedOut
    }

    var syncStatePublisher = PassthroughSubject<SyncStateService.MenuBarState, Never>()

    var syncedTitlePublisher = PassthroughSubject<String, Never>()

    var menuBarState: MenuBarState = .synced

    private var timer: Timer?

    private func lastSyncedDate() -> Date? {
        let lastSyncedKey = UserDefaults.Key.lastSyncedTimeKey.rawValue
        guard let groupUserDefaults = UserDefaults(suiteName: PDCore.Constants.appGroup),
              groupUserDefaults.double(forKey: lastSyncedKey) > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: groupUserDefaults.double(forKey: lastSyncedKey))
    }

    private var syncedTimeDateFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    var syncedTitle: String {
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

    func startTimer() {
        invalidateTimer()
        updateSyncedTitle()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateSyncedTitle()
        }
    }

    func invalidateTimer() {
        timer?.invalidate()
    }

    private func updateSyncedTitle() {
        let title = syncedTitle
        syncedTitlePublisher.send(title)
        Log.debug("syncedTitle: \(syncedTitle)", domain: .syncing)
    }

    deinit {
        invalidateTimer()
    }
}
