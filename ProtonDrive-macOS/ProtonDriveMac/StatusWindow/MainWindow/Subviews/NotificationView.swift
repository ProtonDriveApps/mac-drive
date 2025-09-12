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
import PDUIComponents
import ProtonCoreUIFoundations
import PDLocalization

struct NotificationView: View {

    @ObservedObject var state: ApplicationState

    let action: () -> Void

    var body: some View {
        switch state.notificationState {
        case .error(let errorCount):
            Button(action: action, label: {
                HStack {
                    Text(Localization.notification_issues(num: errorCount))
                        .frame(alignment: .leading)
                    Spacer()
                    HStack(spacing: 4) {
                        Text(Localization.notification_details)
                        Image("chevron-tiny-right")
                            .resizable()
                            .frame(width: 16, height: 16)

                    }
                    .frame(alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .font(.callout)
                .foregroundStyle(Color(ColorProvider.SignalDanger))
            })
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(ColorProvider.SignalDanger.withAlphaComponent(0.1)))

        case .update:
            Button(action: action, label: {
                Text(Localization.notification_update_available)
                    .font(.callout)
                    .foregroundStyle(Color(ColorProvider.SignalInfo))
            })
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(ColorProvider.SignalInfo.withAlphaComponent(0.1)))

        case .resyncFinished:
            Button(action: action, label: {
                Text(state.fullResyncState.description + " (click to dismiss)")
                    .font(.callout)
                    .foregroundStyle(Color(ColorProvider.SignalInfo))
            })
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(ColorProvider.SignalInfo.withAlphaComponent(0.1)))

        case .none:
            EmptyView()
        }
    }
}

#if HAS_QA_FEATURES
struct NotificationView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Text("None:")

            NotificationView(
                state: ApplicationState.mock(),
                action: {}
            )

            Text("Error:")

            NotificationView(
                state: ApplicationState.mock(errorCount: 3),
                action: {}
            )

            Text("Update:")

            NotificationView(
                state: ApplicationState.mock(isUpdateAvailable: true),
                action: {}
            )
        }
        .frame(width: 360, height: 180)
    }
}
#endif
