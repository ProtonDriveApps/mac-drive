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

#if HAS_QA_FEATURES

import SwiftUI

struct QAStateDebuggingView: View {
    @ObservedObject var observer: ApplicationEventObserver
    @ObservedObject var state: ApplicationState

    let actions: UserActions

    var body: some View {
        VStack(spacing: 8) {
            Text("Current state:")

            ScrollView {
                Text("\(state)").multilineTextAlignment(.leading)
            }

            Text("History: (\(observer.syncItemHistory.count) actions)")

            ScrollViewReader { proxy in
                List {
                    ForEach(observer.syncItemHistory.reversed(), id: \.self.id) { item in
                        VStack(alignment: .leading) {
                            Text("\(item.diff)")
                            Text("\(item.date)")
                                .font(.footnote)
                        }
                    }
                }
                .onChange(of: observer.syncItemHistory) { _ in
                    withAnimation {
                        proxy.scrollTo(0, anchor: .top)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct QAStateDebuggingView_Previews: PreviewProvider {
    static var previews: some View {
        let observer = ApplicationEventObserver(
            state: ApplicationState.mockWithErrorItems,
            logoutStateService: nil,
            networkStateService: nil,
            appUpdateService: nil,
            promoCampaignInteractor: nil
        )

        QAStateDebuggingView(
            observer: observer,
            state: ApplicationState(),
            actions: UserActions(delegate: nil)
        )
    }
}

#endif
