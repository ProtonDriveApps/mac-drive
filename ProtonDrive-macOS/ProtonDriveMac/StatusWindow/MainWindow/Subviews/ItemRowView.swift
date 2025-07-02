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
import UniformTypeIdentifiers
import PDLocalization

struct ItemRowView: View {
    let item: ReportableSyncItem
    let actions: UserActions
    let synchronizedProgress: Double
    let isHovering: Bool
    
    var body: some View {
        VStack {
            HStack {
                fileIcon
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                
                itemInformationView
                
                statusIcon
                    .frame(width: 20)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isHovering ? ColorProvider.InteractionDefaultHover : ColorProvider.BackgroundNorm)
            .onTapGesture {
                actions.app.openDriveFolder(fileLocation: item.location)
            }
            .frame(alignment: .leading)
        }
    }
    
    private var fileIcon: Image {
        // Use system icon if available, otherwise fallback to custom one
        systemFileIcon(for: item.filename) ?? Image(iconName)
    }
    
    private var iconName: String {
        // If we decide to switch to system icons and remove this, we can also remove FileTypeAsset
        guard let mimeType = item.mimeType else {
            return FileTypeAsset.FileAssetName.unknown.rawValue
        }
        return FileTypeAsset.shared.getAsset(mimeType)
    }
    
    func systemFileIcon(for filePath: String) -> Image? {
        if let mimeType = item.mimeType, let utType = UTType(
            mimeType: mimeType,
            conformingTo: .data
        ) {
            let icon = NSWorkspace.shared.icon(for: utType)
            return Image(nsImage: icon)
        }
        return nil
    }
    
    private var itemInformationView: some View {
        VStack(alignment: .leading, spacing: 4) {
            // TODO: Use LabeledContent
            Text(item.filename)
                .font(.body)
                .foregroundColor(ColorProvider.TextNorm)
            
            Text(item.stateDescription)
                .font(.footnote)
                .foregroundStyle(item.state == .errored ? ColorProvider.SignalDanger : ColorProvider.TextHint)
        }
        .frame(maxWidth: 350, alignment: .topLeading)
    }
    
    private var statusIcon: some View {
        Group {
            if isHovering {
                Text(Localization.open)
                    .frame(minWidth: 75)
            } else {
                switch item.state {
                case .finished:
                    Image("finished")
                case .errored:
                    Image("errored")
                        .resizable()
                        .frame(width: 16, height: 16)
                case .inProgress:
                    if item.shouldShowIndeterminateProgress {
                        SpinningProgressView(progress: Int(synchronizedProgress), isIndeterminate: item.shouldShowIndeterminateProgress)
                    } else {
                        SpinningProgressView(progress: item.progress)
                    }
                case .cancelled, .excludedFromSync, .undefined:
                    EmptyView()
                }
            }
        }
    }
}

extension ReportableSyncItem {
    /// Since progress is updated after a block has been uploaded/downloaded, it never happens for single-block files or for operations other than uploads/downloads.
    /// In these cases, we show indeterminate progress.
    /// Once the first block has been completed, the progress is larger than 0, which tells us to start displaying determinate progress.
    fileprivate var shouldShowIndeterminateProgress: Bool {
        return progress == 0
    }
}

struct ItemRowView_Previews: PreviewProvider {
    static var reportableErrors = FileProviderOperation.allCases.map { operation in
        SyncItemState.allCases.map { syncState in
            ReportableSyncItem(
                id: UUID().uuidString,
                modificationTime: Date(),
                filename: "IMG_0042-19.jpg",
                location: "/path/to/file",
                mimeType: "image/jpeg",
                fileSize: 1339346742,
                operation: operation,
                state: syncState,
                progress: 80,
                errorDescription: "Error description (\(syncState), \(operation))"
            )
        }
    }.reduce([], +)
    
    static var previews: some View {
        List {
            ForEach(reportableErrors) {
                ItemRowView(
                    item: $0,
                    actions: UserActions(delegate: nil),
                    synchronizedProgress: 33,
                    isHovering: false
                )
                .frame(width: 360, height: 48)
                ItemRowView(
                    item: $0,
                    actions: UserActions(delegate: nil),
                    synchronizedProgress: 75,
                    isHovering: true
                )
                .frame(width: 360, height: 48)
            }
        }
        .frame(width: 380, height: 400)
    }
}
