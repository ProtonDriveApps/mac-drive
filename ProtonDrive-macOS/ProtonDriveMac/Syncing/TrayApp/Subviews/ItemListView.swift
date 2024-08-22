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

    @Binding var items: [ReportableSyncItem]

    @State private var hoveredIndex: Int?

    var baseURL: URL

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    ItemRowView(item: $items[index], baseURL: baseURL, isHovered: .init(
                        get: { hoveredIndex == index },
                        set: { isHovering in
                            hoveredIndex = isHovering ? index : nil
                        }
                    ))
                    .frame(height: 48)
                }
            }
        }
        .frame(minHeight: 282, maxHeight: 324)
        .background(ColorProvider.BackgroundNorm)
    }
}

struct ItemListView_Previews: PreviewProvider {

    static var previewItems: [ReportableSyncItem] {
        [
            ReportableSyncItem(
                id: "id1",
                modificationTime: Date(),
                filename: "IMG_0042-19.jpg",
                location: "Test/IMG_0042-19.jpg",
                mimeType: "image/jpeg",
                fileSize: 1048632,
                operation: .create,
                state: .inProgress,
                description: nil
            ),
            ReportableSyncItem(
                id: "id2",
                modificationTime: Date(),
                filename: "Folder A", 
                location: "Test/Folder A",
                mimeType: nil,
                fileSize: nil,
                operation: .create,
                state: .finished,
                description: nil
            ),
            ReportableSyncItem(
                id: "id3",
                modificationTime: Date(),
                filename: "Domument.pdf", 
                location: "Folder B/Domument.pdf",
                mimeType: "application/pdf",
                fileSize: 116921,
                operation: .modify,
                state: .errored,
                description: "Could not modify error reason"
            )
        ]
    }

    static var previews: some View {
        ItemListView(items: .constant(previewItems), baseURL: URL(fileURLWithPath: ""))
            .frame(width: 360, height: 282)
    }
}
