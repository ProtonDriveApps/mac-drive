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
import PDCore
import ProtonDriveSDK

public struct PhotoAttributes {
    /// Extended attributes
    public let additionalMetadata: [AdditionalMetadata]
    public let captureTime: Date
    public let childrenCount: Int
    /// Photo asset cloud identifier
    public let cloudIdentifier: String
    public let fileSize: Int64
    /// File path
    public let fileURL: URL
    /// Temporary identifier, id is a UUID
    public let identifier: AnyVolumeIdentifier
    /// nil when this is main photo
    public let mainPhotoUid: SDKNodeUid?
    public let mediaType: String
    /// photo name with file extension
    public let name: String
    /// HMAC of `name` with the photo root hash key
    public let nameHash: String
    /// Photo root folder identifier
    public let parentFolderIdentifier: SDKNodeUid
    /// Photo tags
    public let tags: [Int]
    public let uploadID: UUID
    
    /// `PHAsset.modificationDate` as the photo library reported it, `nil` included. Part of the
    /// skippable-cache key, so it must stay exactly what the library pipeline recorded.
    public let assetModificationTime: Date?
    /// Stored modification date, with `nil` already substituted by the import time. Kept private:
    /// it is only the input for `uploadableModificationDate`, and callers reaching for a raw date
    /// want either that or `assetModificationTime`.
    private let modificationDate: Date
    /// `modificationDate` brought inside the range the backend accepts. Use this for anything sent
    /// to the backend or written to the metadata DB, never for cache keys.
    public let uploadableModificationDate: Date

    public init(
        additionalMetadata: [AdditionalMetadata],
        assetModificationTime: Date?,
        captureTime: Date,
        childrenCount: Int,
        cloudIdentifier: String,
        fileSize: Int64,
        fileURL: URL,
        identifier: AnyVolumeIdentifier,
        mainPhotoUid: SDKNodeUid?,
        mediaType: String,
        modificationDate: Date,
        name: String,
        nameHash: String,
        parentFolderIdentifier: SDKNodeUid,
        tags: [Int],
        uploadID: UUID
    ) {
        self.additionalMetadata = additionalMetadata
        self.assetModificationTime = assetModificationTime
        self.captureTime = captureTime
        self.childrenCount = childrenCount
        self.cloudIdentifier = cloudIdentifier
        self.fileSize = fileSize
        self.fileURL = fileURL
        self.identifier = identifier
        self.mainPhotoUid = mainPhotoUid
        self.mediaType = mediaType
        self.modificationDate = modificationDate
        self.name = name
        self.nameHash = nameHash
        self.parentFolderIdentifier = parentFolderIdentifier
        self.tags = tags
        self.uploadID = uploadID
        self.uploadableModificationDate = modificationDate.validPhotoTimestamp
            ?? captureTime.validPhotoTimestamp
            ?? modificationDate.clampedToValidPhotoTimestamp
    }
}
