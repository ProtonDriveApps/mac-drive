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

import PDCore

public extension NodeLocalDTO {
    /// Must be initialized from within the node's managed object context.
    init(node: CoreDataNode) {
        self.objectIDURL = node.objectID.uriRepresentation()
        self.directShareObjectIDURL = node.directShares.first?.objectID.uriRepresentation()
        self.nodeIdentifier = node.identifier
        self.modificationDate = node.modifiedDate
        self.permissions = node.getNodePermissions()
        self.role = node.getNodeRole()
        self.state = node.state
        self.isAvailableOffline = node.isAvailableOffline
        self.isDownloadable = node.isDownloadable
        self.isDownloaded = node.isDownloaded
        self.isEligibleForAvailableOffline = node.isEligibleForAvailableOffline
        self.isMarkedOfflineAvailable = node.isMarkedOfflineAvailable
        self.isFavorite = node.isFavorite
        self.isSharedWithMeRoot = node.isSharedWithMeRoot
        self.editorsCanShare = node.getStandardShare()?.editorsCanShare ?? false

        if let member = node.directShares.first?.members.first {
            self.membership = MembershipDTO(
                inviteTime: member.createTime,
                memberID: member.id,
                sharedBy: SDKAuthor(emailAddress: member.inviter, signatureVerificationError: nil),
                shareID: member.shareID
            )
        } else {
            self.membership = nil
        }
    }
}
