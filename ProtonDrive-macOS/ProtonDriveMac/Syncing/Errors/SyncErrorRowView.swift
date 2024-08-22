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

    @Binding var error: ReportableSyncItem

    var baseURL: URL

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(self.iconName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30)

            itemInformationView

            if let description = error.description {
                reasonView(description: description)
            }
        }
        .frame(height: 36, alignment: .topLeading)
        .frame(minWidth: 476, idealWidth: 476, maxWidth: 876)
        .background(ColorProvider.BackgroundNorm)
        .cornerRadius(8)
    }
}

extension SyncErrorRowView {

    private var iconName: String {
        guard let mimeType = error.mimeType else {
            return FileTypeAsset.FileAssetName.unknown.rawValue
        }
        return FileTypeAsset.shared.getAsset(mimeType)
    }

    private var itemInformationView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(error.filename)
                .font(.system(size: 13))
                .foregroundColor(ColorProvider.TextNorm)

            if let location = error.location {
                Button {
                    open(from: location)
                } label: {
                    Text(isHovering ? "Go to \(location)" : location)
                        .font(.system(size: 13))
                        .foregroundColor(isHovering ? ColorProvider.TextNorm : ColorProvider.TextWeak)
                }
                .buttonStyle(.borderless)
                .scaleEffect(isHovering ? 1.1 : 1)
                .animation(.spring(), value: isHovering)
                .onHover { hover in
                    isHovering = hover
                }
            }
        }
        .frame(maxWidth: 350, alignment: .topLeading)
    }

    private func reasonView(description: String) -> some View {
        Text(description)
            .font(.system(size: 13))
            .foregroundColor(ColorProvider.TextNorm)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func open(from location: String) {
        guard baseURL.startAccessingSecurityScopedResource() else {
            return
        }
        guard let decodedURL = URL(string: location) else {
            NSWorkspace.shared.activateFileViewerSelecting([baseURL])
            return
        }
        let finalURL = baseURL.appendingPathComponent(decodedURL.path)
        NSWorkspace.shared.activateFileViewerSelecting([finalURL])
        baseURL.stopAccessingSecurityScopedResource()
    }
}

struct SyncErrorRowView_Previews: PreviewProvider {
    static var reportableError: ReportableSyncItem {
        ReportableSyncItem(
            id: UUID().uuidString,
            modificationTime: Date(),
            filename: "IMG_0042-19.jpg",
            location: "/path/to/file",
            mimeType: "image/jpeg",
            fileSize: 1339346742,
            operation: .create,
            state: .errored,
            description: "An error's localized description"
        )
    }

    static var previews: some View {
        SyncErrorRowView(error: .constant(reportableError), baseURL: URL(string: "www.proton.me")!)
    }
}
