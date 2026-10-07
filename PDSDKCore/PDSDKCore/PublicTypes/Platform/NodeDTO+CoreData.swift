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
import PDCore

public extension NodeDTO {
    /// Builds the appropriate concrete DTO from a Core Data node.
    ///
    /// Must be called from within the node's managed object context.
    init(node: CoreDataNode, signatureKeys: [PublicKey]) throws {
        switch node {
        case let folder as CoreDataFolder:
            self = .folder(try FolderDTO(folder: folder, signatureKeys: signatureKeys))
        case let file as CoreDataFile:
            self = .file(try FileDTO(file: file, signatureKeys: signatureKeys))
        default:
            throw CoreDataNode.InvalidState(message: "Given node is neither File nor Folder")
        }
    }
}

// Temporary workaround for current iOS FFinderView.
// Decrypting extended attributes for all files is slow and harms UX,
// so we decrypt them on demand instead.
// We can revert to using SDKFileRevision once we implement node enumeration and read data from SDK
public extension NodeDTO {
    func extendedAttributes(performIn context: NSManagedObjectContext) -> ExtendedAttributes {
        guard isFile else { return ExtendedAttributes() }
        do {
            let node: CoreDataFile = try context.typedObject(url: objectIDURL)
            guard let revision = node.activeRevision else { return ExtendedAttributes() }
            return try revision.decryptedExtendedAttributes()
        } catch {
            Log.error("Decrypt extended attributes failed", error: error, domain: .application)
            return ExtendedAttributes()
        }
    }
}
