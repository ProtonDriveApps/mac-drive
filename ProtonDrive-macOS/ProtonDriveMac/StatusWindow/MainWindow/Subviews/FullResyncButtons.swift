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

/// Maps a resync state (plus the recovery affordances the coordinator allows) to the action buttons the UI
/// shows. Pure: same inputs always produce the same output, so button visibility is unit-testable in isolation.
enum FullResyncButtons {

    /// One action button. The array order is "primary action(s) first, then cancel"; the view decides the
    /// on-screen layout (Cancel sits on the left of a side-by-side pair; the recovery set stacks).
    enum Kind: Equatable {
        case pause
        case resume
        case retry
        case createNewLocation
        case cancel
    }

    /// The resync variants, which fully determine the recovery affordances.
    /// - `userInitiated`: keeps a working domain — pausable, cancellable, never offers "create a new sync folder".
    /// - `automatic`: an app-initiated refresh — pausable, but not cancellable while it runs; only errored
    ///   recovery offers Cancel.
    /// - `loginReconnection`: runs against a disconnected domain — not pausable, and Cancel can't return to a
    ///   working state, so recovery offers "create a new sync folder" instead of Cancel.
    enum Context: Equatable {
        case userInitiated
        case automatic
        case loginReconnection
    }

    /// - Parameter context: the resync variant, which determines the recovery affordances (see `Context`).
    static func buttons(for state: ApplicationState.FullResyncState, context: Context) -> [Kind] {
        switch state {
        case .inProgress:
            // The whole scan/download phase is one cancellable engine phase (discovery and downloading only
            // differ by whether a total is known yet), so Pause/Cancel apply throughout it. Once enumeration
            // begins the DBs are already swapped and it can no longer be paused/cancelled.
            switch context {
            case .userInitiated: return [.pause, .cancel]
            case .automatic: return [.pause]           // an automatic refresh can't be cancelled while running
            case .loginReconnection: return [.cancel]  // a login reconnection can't be paused
            }
        case .paused:
            switch context {
            case .userInitiated: return [.resume, .cancel]
            // An automatic refresh can't be cancelled. A login reconnection isn't pausable, so it should
            // never reach .paused — but if it ever did, Cancel couldn't return the disconnected domain to a
            // working state (see .errored below), so offer only the safe way forward.
            case .automatic, .loginReconnection: return [.resume]
            }
        case .errored:
            switch context {
            case .userInitiated, .automatic: return [.retry, .cancel]
            // The domain is disconnected, so Cancel can't return to a working state — offer a fresh start.
            case .loginReconnection: return [.retry, .createNewLocation]
            }
        case .idle, .starting, .enumerating, .completed:
            return []
        }
    }
}
