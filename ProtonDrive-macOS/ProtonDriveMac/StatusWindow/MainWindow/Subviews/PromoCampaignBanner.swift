// Copyright (c) 2025 Proton AG
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

struct PromoCampaignBanner: View {
    @ObservedObject private var state: ApplicationState
    private var actions: UserActions

    init(state: ApplicationState, actions: UserActions) {
        self.state = state
        self.actions = actions
    }

    var body: some View {
        state.visibleCampaign.map { campaign in
            HStack {
                Spacer()
                    .frame(width: 16)
                Label(campaign.text, image: campaign.icon.imageName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(campaign.tintColor)
                Spacer()
                Button(
                    action: { self.actions.promo.dismissPromoBanner() },
                    label: { Image("Promo/ic-cross").tint(campaign.tintColor) }
                )
                    .buttonStyle(.borderless)
                    .tint(campaign.tintColor)
                Spacer()
                    .frame(width: 16)
            }
            .contentShape(Rectangle())
            .onTapGesture { self.actions.promo.goToPromoPageOnWeb(email: state.accountInfo?.email) }
            .frame(minHeight: 36, maxHeight: 36)
            .background(campaign.backgroundColor)
        }
    }
}
