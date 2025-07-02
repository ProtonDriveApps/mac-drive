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
import PDCore

/// Computes and propagates the formatted amount of time elapsed since the last sync.
/// Note that this is only used to update `SyncStateView`, not the individual file operation rows.
class ElapsedTimeService {

    private let timeInterval: TimeInterval = 60

    private let state: ApplicationState

    private var timer: Timer?

    init(state: ApplicationState) {
        self.state = state
        Log.trace()
    }

    /// Start a timer and pass the updated formatted string to the caller every minute.
    @MainActor
    public func startTimer() {
        stopTimer()

        tick()

        let timer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: true) { [weak self] timer in
            self?.tick()
        }
        self.timer = timer
    }

    public func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        Log.trace()
        Self.updateElapsedTime(state: state)
    }

    public static func updateElapsedTime(state: ApplicationState) {
        // if case .synced = self?.state.overallStatus {
        let formattedElapsedTime = Self.formattedElapsedTime(state: state)
        Log.debug("Elapsed time since last sync: \(formattedElapsedTime)", domain: .syncing)

        Task { @MainActor in
            state.formattedTimeSinceLastSync = formattedElapsedTime
        }
    }

    public static func formattedElapsedTime(state: ApplicationState) -> String {
        let title = "Synced"

        guard let lastSyncTime = state.lastSyncTime else {
            return title
        }

        let secondsSinceSync = Date().timeIntervalSince1970 - lastSyncTime

        if secondsSinceSync < 60 {
            return "Synced just now"
        }

        let relativeDateString = Self.syncedTimeDateFormatter.localizedString(
            for: Date(timeIntervalSince1970: lastSyncTime - 1), // to change "in 0 seconds" to "1 second ago"
            relativeTo: Date()
        )

        return "\(title) \(relativeDateString)"
    }

    public static var syncedTimeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    deinit {
        Log.trace()
        stopTimer()
    }
}
