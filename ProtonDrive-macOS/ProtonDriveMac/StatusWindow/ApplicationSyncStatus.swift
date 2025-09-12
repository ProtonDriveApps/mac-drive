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

import PDLocalization

/// The status displayed in the status menu.
///
/// Takes into account multiple variables:
/// - Is the user logged in?
/// - Are there file changes to sync?
/// - Is the network reachable?
/// - Has the user paused syncing?
/// - Is there an app update available?
///
///  The cases are listed in order of priority (i.e. if multiple conditions are true, the earliest one will be displayed)
enum ApplicationSyncStatus: Sendable, Equatable {
    // Source: App launch
    case launching
    // Source: User action
    case signedOut
    // Source: User action
    case paused
    // Source: Network
    case offline
    // Source: FileProvider
    case enumerating(String)
    // Source: FileProvider
    case syncing
    // Source: AppUpdateService
    case updateAvailable
    // Source: FileProvider
    case errored(Int)
    // Source: FileProvider
    case synced
    // Source: User action
    case fullResyncInProgress
    case fullResyncCompleted

    var displayLabel: String {
        switch self {
        case .launching: Localization.menu_status_sync_launching
        case .signedOut: Localization.menu_status_signed_out
        case .paused: Localization.menu_status_sync_paused
        case .offline: Localization.menu_status_offline
        case .enumerating(let itemEnumerationDescription): itemEnumerationDescription
        case .syncing: Localization.menu_status_syncing
        case .updateAvailable: Localization.menu_status_update_available
        case .errored(let errorCount): Localization.menu_status_sync_items_failed(errorCount: errorCount)
        case .synced: Localization.menu_status_synced
        case .fullResyncInProgress: Localization.menu_status_full_resync
        case .fullResyncCompleted: Localization.menu_status_full_resync
        }
    }
}
