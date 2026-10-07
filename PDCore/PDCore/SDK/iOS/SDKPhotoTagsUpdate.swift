// Copyright (c) 2026 Proton AG
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

import Foundation

/// Tag mutation for a single photo
public struct SDKPhotoTagsUpdate: Sendable {
    public let nodeUid: AnyVolumeIdentifier
    /// will be mapping to ProtonDriveSDK.PhotoTag
    public let tagsToAdd: [Int]
    /// will be mapping to ProtonDriveSDK.PhotoTag
    public let tagsToRemove: [Int]

    public init(nodeUid: AnyVolumeIdentifier, tagsToAdd: [Int], tagsToRemove: [Int]) {
        self.nodeUid = nodeUid
        self.tagsToAdd = tagsToAdd
        self.tagsToRemove = tagsToRemove
    }
}
