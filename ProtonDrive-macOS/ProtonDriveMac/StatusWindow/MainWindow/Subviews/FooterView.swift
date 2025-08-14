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
import ProtonCoreUIFoundations

struct FooterView: View {

    @ObservedObject var state: ApplicationState
    let actions: UserActions

    var body: some View {
        HStack(spacing: 40) {
            if !state.canGetMoreStorage {
                Spacer()
            }

            Button(action: { actions.app.openDriveFolder() }, label: {
                Label(
                    title: { Text("Open folder") },
                    icon: { Image( "folder-open") }
                )
            })

            if !state.canGetMoreStorage {
                Spacer()
            }

            Button(action: { actions.links.openOnlineDriveFolder(email: state.accountInfo?.email) }, label: {
                Label(
                    title: { Text("View online") },
                    icon: { Image( "globe") }
                )
            })

            if state.canGetMoreStorage {
                Button(action: { actions.links.getMoreStorage(email: state.accountInfo?.email) }, label: {
                    Label(
                        title: { Text("Add storage") },
                        icon: { Image("bolt") }
                    )
                })
            }

            if !state.canGetMoreStorage {
                Spacer()
            }
        }
        .font(.callout)
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .buttonStyle(.borderless)
        .labelStyle(.vertical)
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity)
        .foregroundStyle(ColorProvider.TextNorm)
        .background(ColorProvider.BackgroundWeak)
    }

    struct ToolbarItem {
        let icon: String
        let label: String
        let action: () -> Void
    }
}

#if HAS_QA_FEATURES
struct FooterView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            FooterView(state: ApplicationState.mock(), actions: UserActions(delegate: nil))
                .frame(width: 360, height: 48)

            FooterView(state: ApplicationState.mock(canGetMoreStorage: false), actions: UserActions(delegate: nil))
                .frame(width: 360, height: 48)
        }
    }
}
#endif
