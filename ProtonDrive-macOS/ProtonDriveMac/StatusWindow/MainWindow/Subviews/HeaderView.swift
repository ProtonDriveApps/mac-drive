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
import PDCore
import ProtonCoreUIFoundations
import PDLocalization

extension AccountInfo {
    var initials: String {
        displayName.initials()
    }
}

struct HeaderView: View {
    @ObservedObject var state: ApplicationState
    
    let actions: UserActions
    
    var body: some View {
        VStack {
            HStack(spacing: 12) {
                if let initials = state.accountInfo?.initials {
                    InitialsView(initials)
                        .frame(width: 34, height: 34)
                }
                
                VStack(alignment: .leading) {
                    if let displayName = state.accountInfo?.email {
                        Text(verbatim: displayName)
                            .font(.body)
                            .foregroundColor(ColorProvider.TextNorm)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    if let userInfo = state.userInfo {
                        Text(userInfo.storageDescription)
                            .font(.system(size: 11))
                            .foregroundColor(ColorProvider.TextWeak)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .foregroundStyle(ColorProvider.TextNorm)
                
                Spacer()
                
                Menu {
                    VStack {
                        if state.isLoggedIn, !state.fullResyncState.isHappening {
                            Button(action: {
                                if state.isPaused {
                                    actions.sync.resumeSyncing()
                                } else {
                                    actions.sync.pauseSyncing()
                                }
                            }, label: {
                                Text(state.isPaused ? Localization.sync_resume : Localization.sync_pause)
                            })
                            
                            Button(Localization.general_settings, action: actions.windows.showSettings)
                        } else {
                            Button(Localization.setting_help_show_logs, action: actions.windows.showLogsInFinder)
                            Button(Localization.setting_help_report_issue, action: actions.links.reportBug)
                        }
                        
#if HAS_QA_FEATURES
                        Button("QA Settings", action: actions.windows.showQASettings)
#endif
                        
                        Button(Localization.general_quit, action: actions.app.quitApp)
                    }
                    .font(.system(size: 15))
                    .foregroundStyle(ColorProvider.BackgroundWeak)
                } label: {
                    Label("", image: "gear")
                        .labelStyle(.iconOnly)
                }
                .frame(width: 34, height: 34)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            .foregroundColor(ColorProvider.BackgroundWeak)
            .frame(maxWidth: .infinity)
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 16)
        }
        .background(state.isLoggedIn ? ColorProvider.BackgroundWeak : ColorProvider.BackgroundNorm)
    }
}

#if HAS_QA_FEATURES
struct HeaderView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            HeaderView(
                state: ApplicationState.mock(),
                actions: UserActions(delegate: nil))
            
            HeaderView(
                state: ApplicationState.mock(isPaused: true),
                actions: UserActions(delegate: nil))
            
            HeaderView(
                state: ApplicationState.mock(loggedIn: false),
                actions: UserActions(delegate: nil))
        }
        .frame(width: 360, height: 200)
    }
}
#endif
