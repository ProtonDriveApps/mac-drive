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

/// Strings used in the UI to report on the state of an individual item (state, progress, time since last sync, etc. )
/// Not to be mistaken with `ApplicationState.displayName(for status: ApplicationSyncStatus)`,
/// which returns a string describing the overall sync state.
extension ReportableSyncItem {
    var stateDescription: String {
        let result = switch state {
        case .inProgress:
            "\(operationDescription) \(progressDescription)"
        case .errored:
            "\(operationDescription) "
        case .finished:
            "\(operationDescription) \(syncTimeDescription) "
        case .cancelled, .excludedFromSync, .undefined:
            "\(syncStateDescription) \(syncTimeDescription) "
        }
        if sizeDescription.isEmpty {
            return result
        } else {
            return "\(result)| \(sizeDescription)"
        }
    }

    var operationDescription: String {
        switch state {
        case .excludedFromSync, .cancelled, .undefined:
            state.description
        case .finished:
            fileProviderOperation.operationDescriptionWhenCompleted
        case .inProgress:
            if progress == 0 {
                fileProviderOperation.operationDescriptionWhenQueued
            } else {
                fileProviderOperation.operationDescriptionWhenInProgress
            }
        case .errored:
            errorDescription ?? "Error"
        }
    }

    var syncStateDescription: String {
        switch state {
        case .cancelled:
            "\(state.description) while \(fileProviderOperation.operationDescriptionWhenInProgress.lowercased())"
        case .excludedFromSync, .undefined:
            "\(state.description)"
        default:
            ""
        }
    }

    private var sizeDescription: String {
        guard let fileSize, fileSize > 0, !isFolder, !fileProviderOperation.isSizeAgnostic else {
            return ""
        }

        return fileSize.formattedFileSize
    }

    private var progressDescription: String {
        if case .inProgress = state, progress > 0 {
            "\(progress)% "
        } else {
            ""
        }
    }

    private var syncTimeDescription: String {
        let secondsSinceSync = Date().timeIntervalSince1970 - modificationTime.timeIntervalSince1970

        if secondsSinceSync < 60 {
            return "just now"
        }

        return ElapsedTimeService.syncedTimeDateFormatter.localizedString(
            for: modificationTime.addingTimeInterval(-1), // to change "in 0 seconds" to "1 second ago"
            relativeTo: Date()
        )
    }
}
