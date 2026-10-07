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

struct PhotoUpdateOperationStreamBuilder {
    static func makeUpdatePhotosStream(
        metadataUpdater: MetadataUpdaterProtocol,
        client: ProtonPhotosClient,
        updates: [PhotoTagsUpdate],
        moc: NSManagedObjectContext
    ) -> AsyncThrowingStream<NodeOperationStreamEvent, Error> {
        if updates.isEmpty {
            return AsyncThrowingStream { continuation in
                continuation.yield(.completed(error: nil))
                continuation.finish()
            }
        }

        return NodeOperationStreamEngine(metadataUpdater: metadataUpdater).streamNodeResults(
            moc: moc,
            applyFailureLogMessage: "Failed to apply local photo update results",
            invoke: { onNodeResult in
                try await client.updatePhotos(updates, onNodeResult: onNodeResult)
            },
            applyBatch: { batch, _ in
                batch.compactMap { result in
                    guard result.error == nil else { return nil }
                    return AnyVolumeIdentifier(id: result.nodeUid.nodeID, volumeID: result.nodeUid.volumeID)
                }
            }
        )
    }
}
