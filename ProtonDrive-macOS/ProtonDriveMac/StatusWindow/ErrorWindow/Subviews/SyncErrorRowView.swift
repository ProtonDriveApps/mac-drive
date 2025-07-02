// Copyright (c) 2023 Proton AG
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

struct SyncErrorRowView: View {

    private let errorItem: ReportableSyncItem
    private let actions: UserActions

    @State private var isHovering = false

    init(errorItem: ReportableSyncItem, actions: UserActions) {
        self.errorItem = errorItem
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(self.iconName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 30)

            VStack {
                itemInformationView
                    .frame(maxWidth: .infinity)
                reasonView(description: errorItem.errorDescription)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 476, idealWidth: 476, maxWidth: 876)
        .background(ColorProvider.BackgroundNorm)
        .cornerRadius(8)
    }

    private var iconName: String {
        guard let mimeType = errorItem.mimeType else {
            return FileTypeAsset.FileAssetName.unknown.rawValue
        }
        return FileTypeAsset.shared.getAsset(mimeType)
    }

    private var itemInformationView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(errorItem.filename)
                .font(.system(size: 13))
                .foregroundColor(ColorProvider.TextNorm)

            if let location = errorItem.location {
                Button {
                    actions.app.openDriveFolder(fileLocation: errorItem.location)
                } label: {
                    Text(isHovering ? "Go to \(location)" : location)
                        .font(.system(size: 13))
                        .foregroundColor(isHovering ? ColorProvider.TextNorm : ColorProvider.TextWeak)
                }
                .buttonStyle(.borderless)
                .animation(.spring(), value: isHovering)
                .onHover { hover in
                    isHovering = hover
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func reasonView(description: String?) -> some View {
        Text(description ?? "")
            .font(.system(size: 13))
            .foregroundColor(ColorProvider.SignalDanger)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if HAS_QA_FEATURES
struct SyncErrorRowView_Previews: PreviewProvider {
    static var previews: some View {
        List {
            ForEach(ApplicationState.mockErroredState) { item in
                SyncErrorRowView(errorItem: item, actions: UserActions(delegate: nil))
            }
        }
    }
}
#endif
