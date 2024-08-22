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

struct ItemRowView: View {

    @Binding var item: ReportableSyncItem

    let baseURL: URL

    @Binding var isHovered: Bool

    var body: some View {
        HStack {
            Image(self.iconName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)

            itemInformationView

            Image(statusImageName)
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isHovered ? ColorProvider.InteractionDefaultHover : ColorProvider.BackgroundNorm)
        .onHover { hovering in
            isHovered = hovering
        }
        .frame(alignment: .leading)
    }
}

private extension ItemRowView {

    private var iconName: String {
        guard let mimeType = item.mimeType else {
            return FileTypeAsset.FileAssetName.unknown.rawValue
        }
        return FileTypeAsset.shared.getAsset(mimeType)
    }

    private var itemState: String {
        switch item.state {
        case .undefined, .finished:
            "Synced"
        case .inProgress:
            "Syncing"
        case .errored:
            item.description ?? "Error"
        @unknown default:
            "Error"
        }

    }

    private var itemInformationView: some View {
        Button(action: {
            open(from: item.location)
        }, label: {
            VStack(alignment: .leading, spacing: 4) {
                // TODO: Use LabeledContent
                Text(item.filename)
                    .font(.body)
                    .foregroundColor(ColorProvider.TextNorm)

                Text(itemState)
                    .font(.footnote)
                    .foregroundStyle(item.state == .errored ? ColorProvider.SignalDanger : ColorProvider.TextWeak)
            }
            .frame(maxWidth: 350, alignment: .topLeading)
        })
        .buttonStyle(.borderless)
    }

    private var statusImageName: String {
        switch item.state {
        case .undefined, .finished:
            "state-checkmark"
        case .inProgress:
            "inProgress"
        case .errored:
            "errored"
        @unknown default:
            ""
        }
    }

    private func open(from location: String?) {
        guard let location = location?.removingPercentEncoding else {
            return
        }
        guard baseURL.startAccessingSecurityScopedResource() else {
            return
        }
        guard let decodedURL = URL(string: location) else {
            NSWorkspace.shared.activateFileViewerSelecting([baseURL])
            return
        }
        let finalURL = baseURL.appendingPathComponent(location)
        NSWorkspace.shared.activateFileViewerSelecting([finalURL])
        baseURL.stopAccessingSecurityScopedResource()
    }

}

struct ItemRowView_Previews: PreviewProvider {

    static var reportableItem: ReportableSyncItem {
       ReportableSyncItem(
            id: "id1",
            modificationTime: Date(),
            filename: "IMG_0042-19.jpg",
            location: "Test/IMG_0042-19.jpg",
            mimeType: "image/jpeg",
            fileSize: 914384,
            operation: .create,
            state: .finished,
            description: nil
        )
    }

    static var previews: some View {
        ItemRowView(
            item: .constant(reportableItem),
            baseURL: URL(string: "www.google.com")!,
            isHovered: .constant(false)
        )
        .frame(width: 360, height: 48)
    }
}
