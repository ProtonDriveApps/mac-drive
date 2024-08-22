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

struct NotificationView: View, Equatable {
    
    @Binding var state: SyncActivityViewModel.NotificationState

    @Binding var errorsCount: Int

    let action: () -> Void

    var body: some View {
        switch state {
        case .error:
            Button(action: action, label: {
                HStack {
                    Text(errorsCount > 1 ? "There are \(errorsCount) issues" : "There is \(errorsCount) issue")
                        .frame(alignment: .leading)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Details")
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
                Text("Update available. Click to restart Proton Drive.")
                    .font(.callout)
                    .foregroundStyle(Color(ColorProvider.SignalInfo))
            })
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(ColorProvider.SignalInfo.withAlphaComponent(0.1)))

        case .none:
            Spacer()
        }
    }

    static func == (lhs: NotificationView, rhs: NotificationView) -> Bool {
        return lhs.state == rhs.state && lhs.errorsCount == rhs.errorsCount
    }
}

struct NotificationView_Previews: PreviewProvider {
    
    static var previews: some View {
        Group {
            NotificationView(
                state: .constant(.error),
                errorsCount: .constant(3),
                action: {}
            )

            NotificationView(
                state: .constant(.update),
                errorsCount: .constant(0),
                action: {}
            )
        }
        .frame(width: 360, height: 42)

    }
}
