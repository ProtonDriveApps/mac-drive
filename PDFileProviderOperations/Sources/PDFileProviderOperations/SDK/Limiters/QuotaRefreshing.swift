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

/// Refreshes the cached user quota so a stale value can self-correct.
/// Used by `QuotaLimiter` to repair the cache after the first blocked upload.
public protocol QuotaRefreshing: Sendable {
    /// Fetches fresh user info and updates the cached quota.
    /// - Returns: `true` if the quota was actually refreshed, `false` if the refresh
    ///   failed (failures are handled/logged by the implementation). The limiter only
    ///   trusts the estimate again after a real refresh.
    func refreshQuota() async -> Bool
}
