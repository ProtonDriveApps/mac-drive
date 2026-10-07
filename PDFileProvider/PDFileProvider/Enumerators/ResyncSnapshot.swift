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

/// The local-only state that has to survive a full resync's metadata rebuild. Written by the main app
/// before the rebuild (`tmp_node_ids.lz4`), then read back by the extension for the delete diff and by the
/// app for the Keep Downloaded restore.
public struct ResyncSnapshot: Codable, Equatable, Sendable {
    /// Every node present before the rebuild — the input to the delete diff.
    public let nodeIdentifiers: [NodeIdentifier]
    /// Subset the user explicitly marked available offline; re-applied after the swap.
    public let markedOfflineAvailable: [NodeIdentifier]

    public init(nodeIdentifiers: [NodeIdentifier], markedOfflineAvailable: [NodeIdentifier]) {
        self.nodeIdentifiers = nodeIdentifiers
        self.markedOfflineAvailable = markedOfflineAvailable
    }
}

public extension ResyncSnapshot {
    /// Encodes to the on-disk snapshot format (JSON + LZ4), mirroring `ResyncDiff.encoded()`.
    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self) as NSData
        return try data.compressed(using: ResyncEnumerationService.nodeIdentifiersTempFileCompressionAlgorithm) as Data
    }

    /// Decodes the format written by `encoded()`, falling back to the legacy bare `[NodeIdentifier]` payload
    /// a prewipe copy can still hold after an app update.
    ///
    /// Only a *root* `typeMismatch` falls back: the legacy payload is a JSON array, so that is the one error a
    /// legacy file produces. Anything else — including a mismatch on a field — means a current-format payload
    /// is corrupt, and its own error says so far more usefully than "expected Array, found Dictionary" would.
    static func decode(from data: Data) throws -> ResyncSnapshot {
        let decompressed = try (data as NSData)
            .decompressed(using: ResyncEnumerationService.nodeIdentifiersTempFileCompressionAlgorithm) as Data
        do {
            return try JSONDecoder().decode(ResyncSnapshot.self, from: decompressed)
        } catch {
            guard let decodingError = error as? DecodingError,
                  case .typeMismatch(_, let context) = decodingError,
                  context.codingPath.isEmpty else {
                throw error
            }
            let legacyIdentifiers = try JSONDecoder().decode([NodeIdentifier].self, from: decompressed)
            return ResyncSnapshot(nodeIdentifiers: legacyIdentifiers, markedOfflineAvailable: [])
        }
    }
}
