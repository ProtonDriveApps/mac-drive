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

public struct FileDTO: Sendable {
    public let sdkFileNode: SDKFileNode
    public let local: NodeLocalDTO

    // File-only UX flags the SDK does not yet model.
    public let canExport: Bool
    public let isBookmark: Bool
    public let isPhoto: Bool
    public let isLocalFile: Bool
    public let isProtonFile: Bool
    public let uploadID: UUID?

    public init(
        sdkFileNode: SDKFileNode,
        local: NodeLocalDTO,
        canExport: Bool = false,
        isBookmark: Bool = false,
        isPhoto: Bool = false,
        isLocalFile: Bool = false,
        isProtonFile: Bool = false,
        uploadID: UUID? = nil
    ) {
        self.sdkFileNode = sdkFileNode
        self.local = local
        self.canExport = canExport
        self.isBookmark = isBookmark
        self.isPhoto = isPhoto
        self.isLocalFile = isLocalFile
        self.isProtonFile = isProtonFile
        self.uploadID = uploadID
    }
}

// MARK: - File only conveniences (false / nil for folders)
public extension NodeDTO {
    var isFile: Bool {
        switch self {
        case .file: return true
        case .folder: return false
        }
    }
    
    var canExport: Bool {
        switch self {
        case .file(let file): return file.canExport
        case .folder:  return false
        }
    }

    var isBookmark: Bool {
        switch self {
        case .file(let file): return file.isBookmark
        case .folder: return false
        }
    }

    var isPhoto: Bool {
        switch self {
        case .file(let file): return file.isPhoto
        case .folder: return false
        }
    }

    var isLocalFile: Bool {
        switch self {
        case .file(let file): return file.isLocalFile
        case .folder: return false
        }
    }

    var isProtonFile: Bool {
        switch self {
        case .file(let file): return file.isProtonFile
        case .folder: return false
        }
    }

    var uploadID: UUID? {
        switch self {
        case .file(let file): return file.uploadID
        case .folder: return nil
        }
    }
}
