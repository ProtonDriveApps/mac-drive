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
import ProtonDriveSDK

extension CoreDataNode {
    func getSDKMembership() -> SDKMembership? {
        guard isSharedWithMeRoot, let member = directShares.first?.members.first else { return nil }
        return SDKMembership(
            role: SDKMemberRole(permissions: Permissions(rawValue: member.permissions)),
            inviteTime: member.createTime.timeIntervalSince1970,
            sharedBy: SDKAuthor(emailAddress: member.inviter, signatureVerificationError: nil)
        )
    }

    func getSDKDirectRole() -> SDKMemberRole {
        getSDKMembership()?.role ?? .inherited
    }
}

extension SDKMemberRole {
    init(permissions: Permissions?) {
        switch permissions {
        case .administrate:
            self = .admin
        case .edit:
            self = .editor
        case .view, nil:
            self = .viewer
        }
    }
}
