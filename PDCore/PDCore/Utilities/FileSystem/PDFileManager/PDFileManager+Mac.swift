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

#if os(macOS)
import CryptoKit
import Foundation

extension PDFileManager {
    /// Creates a random subfolder under cleartext cache directory, returns new URL with requested last component
    public static func prepareUrlForFile(named filename: String) -> URL {
        let filename = filename.filenameSanitizedForFilesystem()
        let url = self.cleartextCacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.createIfNeeded(url)
        return url.appendingPathComponent(filename)
    }
    
    /// Look up a node's cleartext file in the disposable cache; optionally create its folder.
    public static func prepareTempURLForFile(
        identifier: NodeIdentifier,
        named filename: String,
        shouldCreate: Bool
    ) -> URL {
        revisionCacheURL(root: cleartextCacheDirectory, identifier: identifier, filename: filename, shouldCreate: shouldCreate)
    }
    
    /// Look up a node's cleartext file in persistent app-group storage; optionally create its folder.
    public static func preparePermanentURLForFile(
        identifier: NodeIdentifier,
        named filename: String,
        shouldCreate: Bool
    ) -> URL {
        revisionCacheURL(root: permanentDataDirectory, identifier: identifier, filename: filename, shouldCreate: shouldCreate)
    }

    private static func revisionCacheURL(root: URL, identifier: NodeIdentifier, filename: String, shouldCreate: Bool) -> URL {
        // Length-prefix identifiers so different volume/node pairs cannot have the same input.
        // Hashing also prevents identifiers from becoming filesystem path components.
        let key = "\(identifier.volumeID.utf8.count):\(identifier.volumeID)\(identifier.nodeID.utf8.count):\(identifier.nodeID)"
        let directoryName = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        if shouldCreate {
            createIfNeeded(directory)
        }
        return directory.appendingPathComponent(filename.filenameSanitizedForFilesystem())
    }
    
    public static func copyDatabases(from source: URL, to destination: URL) throws {
#if INCLUDES_DB_IN_BUGREPORT
        // Metadata
        let metadata_sqlite = source.appendingPathComponent("Metadata.sqlite")
        let metadata_sqlite_shm = source.appendingPathComponent("Metadata.sqlite-shm")
        let metadata_sqlite_wal = source.appendingPathComponent("Metadata.sqlite-wal")
        
        // Events
        let events_sqlite = source.appendingPathComponent("EventStorageModel.sqlite")
        let events_sqlite_shm = source.appendingPathComponent("EventStorageModel.sqlite-shm")
        let events_sqlite_wal = source.appendingPathComponent("EventStorageModel.sqlite-wal")
        
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: nil)
        }
        
        try? FileManager.default.removeItem(at: destination.appendingPathComponent("Metadata.sqlite"))
        try? FileManager.default.removeItem(at: destination.appendingPathComponent("Metadata.sqlite-shm"))
        try? FileManager.default.removeItem(at: destination.appendingPathComponent("Metadata.sqlite-wal"))
        
        try? FileManager.default.removeItem(at: destination.appendingPathComponent("EventStorageModel.sqlite"))
        try? FileManager.default.removeItem(at: destination.appendingPathComponent("EventStorageModel.sqlite-shm"))
        try? FileManager.default.removeItem(at: destination.appendingPathComponent("EventStorageModel.sqlite-wal"))
        
        try FileManager.default.copyItem(at: metadata_sqlite, to: destination.appendingPathComponent("Metadata.sqlite"))
        try FileManager.default.copyItem(at: metadata_sqlite_shm, to: destination.appendingPathComponent("Metadata.sqlite-shm"))
        try FileManager.default.copyItem(at: metadata_sqlite_wal, to: destination.appendingPathComponent("Metadata.sqlite-wal"))
        
        try FileManager.default.copyItem(at: events_sqlite, to: destination.appendingPathComponent("EventStorageModel.sqlite"))
        try FileManager.default.copyItem(at: events_sqlite_shm, to: destination.appendingPathComponent("EventStorageModel.sqlite-shm"))
        try FileManager.default.copyItem(at: events_sqlite_wal, to: destination.appendingPathComponent("EventStorageModel.sqlite-wal"))
#endif
    }
}
#endif
