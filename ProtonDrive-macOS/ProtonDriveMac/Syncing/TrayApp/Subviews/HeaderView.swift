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
import Combine
import ProtonCoreUIFoundations

struct HeaderView: View, Equatable {
    let initials: String?
    let displayName: String?
    let emailAddress: String?

    let syncingPausedSubject: CurrentValueSubject<Bool, Never>

    @State private var isSyncingPaused = false

    let shouldShowAccountActions: Bool
    let actions: Actions

    struct Actions {
        let pauseSyncing: () -> Void
        let resumeSyncing: () -> Void
        let showSettings: () -> Void
        #if HAS_QA_FEATURES
        let showQASettings: () -> Void
        #endif
        let showLogsInFinder: () -> Void
        let reportBug: () -> Void
        let quitApp: () -> Void
    }

    var body: some View {
        HStack(spacing: 12) {
            if let initials {
                InitialsView(initials)
                    .frame(width: 34, height: 34)
            }

            VStack(alignment: .leading) {
                if let displayName {
                    Text(displayName)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let emailAddress {
                    Text(verbatim: emailAddress)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(ColorProvider.TextNorm)

            Spacer()

            Menu {
                VStack {
                    if shouldShowAccountActions {
                        Button(action: {
                            if isSyncingPaused {
                                actions.resumeSyncing()
                            } else {
                                actions.pauseSyncing()
                            }
                        }, label: {
                            Text(isSyncingPaused ? "Resume Syncing" : "Pause Syncing")
                        })

                        Button("Settings") { actions.showSettings() }
                    } else {
                        Button("Show Logs") { actions.showLogsInFinder() }
                        Button("Report an Issue...") { actions.reportBug() }
                    }

                    #if HAS_QA_FEATURES
                    Button("QA Settings") { actions.showQASettings() }
                    #endif

                    Button("Quit") { actions.quitApp() }
                }
                .font(.system(size: 15))
                .foregroundStyle(ColorProvider.BackgroundWeak)
            } label: {
                Label("", image: "gear")
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 34)
            }
            .frame(width: 34, height: 34)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .onReceive(syncingPausedSubject) { newValue in
            isSyncingPaused = newValue
        }
        .foregroundStyle(ColorProvider.BackgroundWeak)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    static func == (lhs: HeaderView, rhs: HeaderView) -> Bool {
        return lhs.initials == rhs.initials &&
        lhs.displayName == rhs.displayName &&
        lhs.emailAddress == rhs.emailAddress
    }
}

struct HeaderView_Previews: PreviewProvider {

    static var actions: HeaderView.Actions {
        #if HAS_QA_FEATURES
        .init(
            pauseSyncing: {},
            resumeSyncing: {},
            showSettings: {},
            showQASettings: {},
            showLogsInFinder: {},
            reportBug: {},
            quitApp: {}
        )
        #else
        .init(
            pauseSyncing: {},
            resumeSyncing: {},
            showSettings: {},
            showLogsInFinder: {},
            reportBug: {},
            quitApp: {}
        )
        #endif
    }

    static var previews: some View {
        Group {
            HeaderView(
                initials: "AS",
                displayName: "Audrey Sobgou Zebaze",
                emailAddress: "audrey.zebaze@proton.ch", 
                syncingPausedSubject: CurrentValueSubject<Bool, Never>(false),
                shouldShowAccountActions: true,
                actions: actions
            )

            HeaderView(
                initials: nil,
                displayName: "Audrey Sobgou Zebaze",
                emailAddress: "audrey.zebaze@proton.ch",
                syncingPausedSubject: CurrentValueSubject<Bool, Never>(true),
                shouldShowAccountActions: true,
                actions: actions
            )
        }
        .frame(width: 360, height: 62)
    }
}
