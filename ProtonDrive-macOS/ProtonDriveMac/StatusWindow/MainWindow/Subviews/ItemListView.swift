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

struct ItemListView: View {

    @ObservedObject private var state: ApplicationState

    private var actions: UserActions

    /// Index of the row being hovered over.
    @State var indexOfRowBeingHoveredOver: Int = -1

    init(state: ApplicationState, actions: UserActions) {
        self.state = state
        self.actions = actions
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                TimelineView(.periodic(from: Date.now, by: 0.04)) { context in
                    ForEach(Array(state.throttledItems.enumerated()), id: \.element) { index, item in
                        ItemRowView(
                            item: item,
                            actions: actions,
                            synchronizedProgress: context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 100,
                            isHovering: indexOfRowBeingHoveredOver == index
                        )
                        .frame(height: 48)
                        .onHover { isHovering in
                            if isHovering {
                                self.indexOfRowBeingHoveredOver = index
                            } else if self.indexOfRowBeingHoveredOver == index {
                                self.indexOfRowBeingHoveredOver = -1
                            }
                        }
                    }
                }
            }
        }
        .frame(minHeight: 282, maxHeight: 324)
        .background(ColorProvider.BackgroundNorm)
    }
}

#if HAS_QA_FEATURES
struct ItemListView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            ItemListView(state:
                            ApplicationState.mock(
                                totalFilesLeftToSync: 40,
                                items: ApplicationState.mockItems
                            ),
                         actions: UserActions(delegate: nil)
            )
            .frame(width: 360, height: 282)
        }
    }
}
#endif
