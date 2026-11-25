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

struct SaveToTimelineOperationStreamBuilder {
    static func makeSavePhotosToTimelineStream(
        metadataUpdater: MetadataUpdaterProtocol,
        client: ProtonPhotosClient,
        photoUids: [SDKNodeUid],
        cancellationToken: UUID,
        moc: NSManagedObjectContext
    ) -> AsyncThrowingStream<NodeOperationStreamEvent, Error> {
        if photoUids.isEmpty {
            return AsyncThrowingStream { continuation in
                continuation.yield(.completed(error: nil))
                continuation.finish()
            }
        }

        return SDKOperationStreamEngine(metadataUpdater: metadataUpdater).streamNodeResults(
            moc: moc,
            applyFailureLogMessage: "Failed to apply save to timeline results",
            invoke: { onNodeResult in
                try await client.savePhotosToTimeline(
                    photoUids: photoUids,
                    cancellationToken: cancellationToken,
                    onNodeResult: onNodeResult
                )
            },
            // The copied photos reach the local DB through events
            applyBatch: { _, _ in [] },
            onCancel: {
                do {
                    try await client.cancelSavePhotosToTimeline(cancellationToken: cancellationToken)
                } catch {
                    Log.error("Failed to cancel save to timeline", error: error, domain: .sdk)
                }
            }
        )
    }
}
