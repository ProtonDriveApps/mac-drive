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

import Foundation
import PDCore
import PDDesktopDevKit
import ProtonDriveProtos

extension Node {
    func decryptNameWithDDK(protonDriveClient: ProtonDriveClient, volumeId: String) throws -> String {
        do {
            if !PDCore.Constants.runningInExtension {
                // Looks like file providers do no exchange updates across contexts properly
                if let cached = self.clearName {
                    return cached
                }

                // Node can be a fault on in the file providers at this point
                guard !isFault else { return Self.unknownNamePlaceholder }
            }

            guard let name = self.name else {
                throw Errors.noName
            }

            let filename = try parentNode.map { parentNode in
                let nodeNameDecryptionRequest = NodeNameDecryptionRequest.with {
                    $0.nodeIdentity.shareID.value = shareID
                    $0.nodeIdentity.nodeID.value = parentNode.id
                    $0.nodeIdentity.volumeID.value = volumeId
                    $0.armoredEncryptedName = name
                    if let signatureEmail = self.signatureEmail {
                        $0.signatureEmailAddress = signatureEmail
                    }
                }
                let cancellationTokenSource = CancellationTokenSource()
                return try protonDriveClient.decryptNodeName(nodeNameDecryptionRequest: nodeNameDecryptionRequest,
                                                             cancellationTokenSource: cancellationTokenSource)
            } ?? "Proton Drive"

            self.clearName = filename
            return filename
        } catch {
            Log.error(error: DecryptionError(error, "Node Name", description: "LinkID: \(id) \nVolumeID: \(volumeID)"), domain: .encryption)
            throw error
        }
    }
}

extension PDCore.Revision {
    public func decryptedExtendedAttributesWithDDK(protonDriveClient: ProtonDriveClient,
                                                   volumeId: String) throws -> ExtendedAttributes {
        guard let moc = self.moc else {
            throw Revision.noMOC()
        }

        return try moc.performAndWait {
            if let clearXAttributes { return clearXAttributes }

            do {
                guard let xAttributes = self.xAttributes else {
                    throw Errors.noFileMeta
                }

                let nodeNameDecryptionRequest = NodeNameDecryptionRequest.with {
                    $0.nodeIdentity.nodeID.value = self.file.id
                    $0.nodeIdentity.volumeID.value = volumeId
                    $0.nodeIdentity.shareID.value = self.file.shareID
                    $0.armoredEncryptedName = xAttributes
                    if let signatureEmail = self.file.signatureEmail {
                        $0.signatureEmailAddress = signatureEmail
                    }
                }

                let cancellationTokenSource = CancellationTokenSource()
                let attributes = try protonDriveClient.decryptNodeName(nodeNameDecryptionRequest: nodeNameDecryptionRequest,
                                                                       cancellationTokenSource: cancellationTokenSource)

                let cleanAttributes = attributes.reversed().split(separator: "}}").last!.reversed() + "}}"

                let data = cleanAttributes.data(using: .utf8)

                let xAttr = try JSONDecoder().decode(ExtendedAttributes.self, from: data!)
                clearXAttributes = xAttr
                return xAttr
            } catch {
                Log.error(error: DecryptionError(error, "ExtendedAttributes", description: "RevisionID: \(id) \nLinkID: \(file.id) \nVolumeID: \(file.volumeID)"), domain: .encryption)
                throw error
            }
        }
    }
}
