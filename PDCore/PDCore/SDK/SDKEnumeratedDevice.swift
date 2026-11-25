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

/// Device returned by `ProtonDriveSDK` enumeration, mirrors `ProtonDriveSDK.Device` with PDCore types.
public struct SDKEnumeratedDevice: Equatable, Sendable {
    /// SDK device uid, equal to the device ID.
    public let uid: String
    public let type: CoreDataDecryptedDevice.DeviceType
    /// `nil` when the SDK failed to decrypt or validate the name, see `nameError`.
    public let name: String?
    public let nameError: String?
    public let rootFolderUid: AnyVolumeIdentifier
    public let creationTime: Date
    public let lastSyncTime: Date?
    public let shareID: String

    public init(
        uid: String,
        type: CoreDataDecryptedDevice.DeviceType,
        name: String?,
        nameError: String?,
        rootFolderUid: AnyVolumeIdentifier,
        creationTime: Date,
        lastSyncTime: Date?,
        shareID: String
    ) {
        self.uid = uid
        self.type = type
        self.name = name
        self.nameError = nameError
        self.rootFolderUid = rootFolderUid
        self.creationTime = creationTime
        self.lastSyncTime = lastSyncTime
        self.shareID = shareID
    }

    /// Legacy identifier, `nodeID` is the device root folder ID.
    public var identifier: DeviceIdentifier {
        DeviceIdentifier(id: uid, nodeID: rootFolderUid.id, shareID: shareID, volumeID: rootFolderUid.volumeID)
    }
}
