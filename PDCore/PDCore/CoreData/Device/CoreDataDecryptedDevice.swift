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

import CoreData

/// Device enumerated through the SDK. Holds decrypted data only and is independent from the legacy `Device` graph.
@objc(CoreDataDecryptedDevice)
public class CoreDataDecryptedDevice: NSManagedObject, VolumeUnique {
    /// SDK device uid, equal to the device ID.
    @NSManaged public var id: String
    @NSManaged public var volumeID: String
    @NSManaged public var shareID: String
    @NSManaged public var rootFolderID: String
    /// `nil` when the SDK failed to decrypt or validate the name, see `nameError`.
    @NSManaged public var name: String?
    @NSManaged public var nameError: String?
    @NSManaged public var type: DeviceType
    @NSManaged public var createTime: Date
    @NSManaged public var lastSyncTime: Date?

    @objc public enum DeviceType: Int16, Sendable {
        case windows = 1
        case macOS = 2
        case linux = 3
    }

    public var identifier: DeviceIdentifier {
        DeviceIdentifier(id: id, nodeID: rootFolderID, shareID: shareID, volumeID: volumeID)
    }

    @nonobjc public class func fetchRequest() -> NSFetchRequest<CoreDataDecryptedDevice> {
        return NSFetchRequest<CoreDataDecryptedDevice>(entityName: "CoreDataDecryptedDevice")
    }
}
