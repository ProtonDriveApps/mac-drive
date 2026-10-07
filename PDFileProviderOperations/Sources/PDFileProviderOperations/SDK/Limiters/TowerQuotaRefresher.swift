// Copyright (c) 2026 Proton AG
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
@preconcurrency import PDCore

/// Refreshes the cached quota by fetching fresh user info through Tower.
/// A failed refresh is non-fatal: the limiter still recovers via its per-window
/// re-probe, so the error is logged and swallowed.
struct TowerQuotaRefresher: QuotaRefreshing, @unchecked Sendable {
    let tower: Tower

    func refreshQuota() async -> Bool {
        do {
            try await tower.refreshUserInfo()
            return true
        } catch {
            Log.error("Quota self-heal refresh failed", error: error, domain: .sdk, sendToSentryIfPossible: false)
            return false
        }
    }
}
