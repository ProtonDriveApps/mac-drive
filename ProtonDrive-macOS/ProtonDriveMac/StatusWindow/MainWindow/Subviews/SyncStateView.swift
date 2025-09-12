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

/// Displays the current state of syncing below the list of files
struct SyncStateView: View {
    @ObservedObject var state: ApplicationState

    let action: () -> Void

    var body: some View {
        HStack {
            Label {
                Text(state.displayName(for: state.overallStatus))
                    .font(.callout)
                    .foregroundStyle(ColorProvider.TextNorm)
            } icon: {
                overallStatusIcon
                    .frame(width: 16, height: 16)
            }
            Spacer()
            if state.overallStatus == .paused {
                Button("Resume", action: action)
                    .font(.callout)
                    .foregroundStyle(ColorProvider.TextNorm)
                    .buttonStyle(.borderless)
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(ColorProvider.BackgroundNorm)
    }

    @ViewBuilder
    private var overallStatusIcon: some View {
        switch state.overallStatus {
        case .paused:
            Image("pause")
        case .offline:
            Image("cloud-slash")
        case .syncing,
                .enumerating,
                .launching,
                .fullResyncInProgress:
            SpinningImage("syncing", duration: 2)
        case .errored:
            Image("errored")
                .resizable()
                .tint(ColorProvider.SignalDanger)
        case .synced,
                .signedOut,
                .updateAvailable,
                .fullResyncCompleted:
            Image("synced")
                .renderingMode(.template)
                .foregroundStyle(ColorProvider.SignalSuccess)
        }
    }
}

#if HAS_QA_FEATURES
struct SyncStateView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            SyncStateView(state: ApplicationState.mock(isPaused: true)) {}
            SyncStateView(state: ApplicationState.mock(isOffline: true)) {}
            SyncStateView(state: ApplicationState.mock(errorCount: 10)) {}
            SyncStateView(state: ApplicationState.mock(isSyncing: true)) {}
            SyncStateView(state: ApplicationState.mock(secondsAgo: -100)) {}
            SyncStateView(state: ApplicationState.mock(secondsAgo: 30)) {}
            SyncStateView(state: ApplicationState.mock(secondsAgo: 300)) {}
            SyncStateView(state: ApplicationState.mock(secondsAgo: 3000)) {}
            SyncStateView(state: ApplicationState.mock(secondsAgo: 30000)) {}
            SyncStateView(state: ApplicationState.mock(secondsAgo: 300000)) {}
        }
        .frame(width: 360)
    }
}
#endif
