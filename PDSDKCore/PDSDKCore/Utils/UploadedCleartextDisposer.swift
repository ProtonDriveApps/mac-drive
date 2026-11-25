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

#if os(iOS)
import Foundation
import PDCore

public protocol UploadedCleartextDisposerProtocol: Sendable {
    func dispose(fileURL: URL, as disposition: UploadedCleartextDisposition, identifier: NodeIdentifier)
}

public struct UploadedCleartextDisposer: UploadedCleartextDisposerProtocol {
    public init() {}
    
    public func dispose(fileURL: URL, as disposition: UploadedCleartextDisposition, identifier: NodeIdentifier) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            switch disposition {
            case .keepPermanently:
                try move(fileURL, to: .permanent, identifier: identifier)
            case .keepTemporarily:
                try move(fileURL, to: .temporary, identifier: identifier)
            case .discard:
                try FileManager.default.removeItem(at: fileURL)
                removeUploadFolderIfEmpty(containing: fileURL)
            }
        } catch {
            Log.error("Failed to dispose of cleartext of upload \(identifier.nodeID)", error: error, domain: .storage)
        }
    }

    private func move(_ fileURL: URL, to storageType: FileStorageType, identifier: NodeIdentifier) throws {
        let destination = PDFileManager
            .fileURL(for: identifier, prefix: nil, storageType: storageType, shouldCreate: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: fileURL, to: destination)
    }

    private func removeUploadFolderIfEmpty(containing fileURL: URL) {
        let folder = fileURL.deletingLastPathComponent()
        let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard contents?.isEmpty == true else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
#endif
