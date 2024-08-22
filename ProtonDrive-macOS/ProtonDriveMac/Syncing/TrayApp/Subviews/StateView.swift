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

import SwiftUI
import PDCore
import ProtonCoreUIFoundations

struct StateView: View {
    
    @SettingsStorage(UserDefaults.Key.lastSyncedTimeKey.rawValue)
    private(set) var lastSyncedTime: TimeInterval?

    @Binding var state: SyncActivityViewModel.SyncOverallStatus
    @Binding var syncedTitle: String

    let action: () -> Void

    private var text: String {
        switch state {
        case .paused: return "Sync paused"
        case .offline: return "Offline"
        case .errored: return "Some items failed to sync"
        case .inProgress: return "Syncing..."
        case .synced: return syncedTitle
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .paused:
            Image("pause")
        case .offline:
            Image("cloud-slash")
        case .inProgress:
            Image("syncing")
        case .errored:
            Image("errored")
                .tint(ColorProvider.SignalDanger)
        case .synced:
            Image("synced")
                .renderingMode(.template)
                .foregroundStyle(ColorProvider.SignalSuccess)
        }
    }

    var body: some View {
        HStack {
            Label {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(ColorProvider.TextNorm)
            } icon: {
                icon
            }
            Spacer()
            if state == .paused {
                Button("Resume", action: action)
                    .font(.callout)
                    .foregroundStyle(ColorProvider.TextNorm)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(ColorProvider.BackgroundNorm)
    }
}

struct StateView_Previews: PreviewProvider {

    static var previews: some View {
        Group {
            StateView(state: .constant(.paused), syncedTitle: .constant("Synced 8 minutes ago")) {}
                .frame(width: 360, height: 28)
            StateView(state: .constant(.offline), syncedTitle: .constant("Synced 1 hour ago")) {}
                .frame(width: 360, height: 28)
            StateView(state: .constant(.errored), syncedTitle: .constant("Synced 8 minutes ago")) {}
                .frame(width: 360, height: 28)
            StateView(state: .constant(.inProgress), syncedTitle: .constant("Synced just now")) {}
                .frame(width: 360, height: 28)
            StateView(state: .constant(.synced), syncedTitle: .constant("Synced 4 hours ago")) {}
                .frame(width: 360, height: 28)
        }

    }
}
