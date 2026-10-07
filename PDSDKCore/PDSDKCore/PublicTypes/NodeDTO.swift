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
import Foundation
@preconcurrency import PDCore
import ProtonDriveSDK

// MARK: - NodeDTO

/// Public sum type representing a node rendered in finder-style lists.
///
/// Mirrors the shape of `SDKDriveNode` so the discrimination is encoded once.
/// SDK-backed metadata (id, name, dates, authors, mime type) lives on the
/// stored `SDKFileNode` / `SDKFolderNode`; only fields the SDK does not yet
/// cover are mirrored locally on `NodeLocalDTO` and on each case's payload.
///
/// As the SDK gains parity, fields can be removed from `NodeLocalDTO` and
/// eventually the DTOs themselves can be retired in favour of `SDKDriveNode`
/// at call sites.
public enum NodeDTO: Identifiable, Sendable {
    case file(FileDTO)
    case folder(FolderDTO)

    var sdkDriveNode: SDKDriveNode {
        switch self {
        case .file(let file): return .file(file.sdkFileNode)
        case .folder(let folder): return .folder(folder.sdkFolderNode)
        }
    }

    public var local: NodeLocalDTO {
        switch self {
        case .file(let file): return file.local
        case .folder(let folder): return folder.local
        }
    }
}

// MARK: - Flat convenience accessors

/// Making it obvious which fields will disappear once the SDK is feature-complete.
public extension NodeDTO {

    // MARK: SDK-backed

    var id: AnyVolumeIdentifier { sdkDriveNode.uid.any }
    var parentID: AnyVolumeIdentifier? { sdkDriveNode.parentUid?.any }
    var name: String { sdkDriveNode.name }
    var createdDate: Date { Date(timeIntervalSince1970: sdkDriveNode.creationTime) }
    var nameAuthor: SDKAuthor? { sdkDriveNode.nameAuthor }
    var keyAuthor: SDKAuthor? { sdkDriveNode.keyAuthor }
    var ownedBy: String? { sdkDriveNode.ownedBy.email ?? sdkDriveNode.ownedBy.organization }
    var activeRevision: SDKFileRevision? { sdkDriveNode.activeRevision }
    var mimeType: String {
        switch self {
        case .file(let file): return file.sdkFileNode.mediaType
        case .folder: return Folder.mimeType
        }
    }
    var isShared: Bool { sdkDriveNode.isShared }

    // MARK: Local-backed

    var objectIDURL: URL { local.objectIDURL }
    var directShareObjectIDURL: URL? { local.directShareObjectIDURL }
    var nodeIdentifier: NodeIdentifier { local.nodeIdentifier }
    var modificationDate: Date { local.modificationDate }
    var permissions: Permissions { local.permissions }
    var role: Role { local.role }
    var state: Node.State? { local.state }
    var membership: MembershipDTO? { local.membership }
    var isAvailableOffline: Bool { local.isAvailableOffline }
    var isDownloadable: Bool { local.isDownloadable }
    var isDownloaded: Bool { local.isDownloaded }
    var isEligibleForAvailableOffline: Bool { local.isEligibleForAvailableOffline }
    var isMarkedOfflineAvailable: Bool { local.isMarkedOfflineAvailable }
    var isFavorite: Bool { local.isFavorite }
    var isSharedWithMeRoot: Bool { local.isSharedWithMeRoot }
}

// MARK: - NodeLocalDTO

/// Local-only metadata not yet covered by the SDK. As the SDK gains parity,
/// remove fields here and switch their callers to read from the SDK node.
public struct NodeLocalDTO: Sendable {
    public let directShareObjectIDURL: URL?
    public let isAvailableOffline: Bool
    public let isDownloadable: Bool
    public let isDownloaded: Bool
    public let isEligibleForAvailableOffline: Bool
    public let isFavorite: Bool
    public let isMarkedOfflineAvailable: Bool
    public let isSharedWithMeRoot: Bool
    public let editorsCanShare: Bool
    public let membership: MembershipDTO?
    public let modificationDate: Date
    public let nodeIdentifier: NodeIdentifier
    public let objectIDURL: URL
    public let permissions: Permissions
    public let role: Role
    public let state: Node.State?

    public init(
        objectIDURL: URL,
        nodeIdentifier: NodeIdentifier,
        state: Node.State?,
        directShareObjectIDURL: URL?,
        modificationDate: Date,
        permissions: Permissions,
        role: Role,
        membership: MembershipDTO?,
        isAvailableOffline: Bool,
        isDownloadable: Bool,
        isDownloaded: Bool,
        isEligibleForAvailableOffline: Bool,
        isFavorite: Bool,
        isMarkedOfflineAvailable: Bool,
        isSharedWithMeRoot: Bool,
        editorsCanShare: Bool
    ) {
        self.objectIDURL = objectIDURL
        self.directShareObjectIDURL = directShareObjectIDURL
        self.nodeIdentifier = nodeIdentifier
        self.modificationDate = modificationDate
        self.permissions = permissions
        self.role = role
        self.state = state
        self.membership = membership
        self.isAvailableOffline = isAvailableOffline
        self.isDownloadable = isDownloadable
        self.isDownloaded = isDownloaded
        self.isEligibleForAvailableOffline = isEligibleForAvailableOffline
        self.isFavorite = isFavorite
        self.isMarkedOfflineAvailable = isMarkedOfflineAvailable
        self.isSharedWithMeRoot = isSharedWithMeRoot
        self.editorsCanShare = editorsCanShare
    }
}
