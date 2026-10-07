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
import PDCore
import PDSDKCore
import ProtonCoreUtilities

struct VolumeBatchPerformerResolver {
    /// [VolumeID: isFilePerformer]
    @ThreadSafe private var volumePerformerCache: [String: Bool] = [:]

    /// Shared volume → performer selection for tests and call sites that use the same concrete type for both performers.
    func performer<T>(
        for volumeID: String,
        volumeIDs: StorageManager.VolumeIDs,
        filePerformer: T,
        photoPerformer: T,
        context: NSManagedObjectContext
    ) async -> T {
        let useFilePerformer = await usesFilePerformer(for: volumeID, volumeIDs: volumeIDs, context: context)
        return useFilePerformer ? filePerformer : photoPerformer
    }

    private func usesFilePerformer(
        for volumeID: String,
        volumeIDs: StorageManager.VolumeIDs,
        context: NSManagedObjectContext
    ) async -> Bool {
        switch volumeID {
        case volumeIDs.main:
            return true
        case volumeIDs.photo:
            return false
        default:
            if let isFile = volumePerformerCache[volumeID] {
                return isFile
            }
            let isFile: Bool = await context.perform {
                guard let volume = CoreDataVolume.fetch(id: volumeID, in: context) else { return true }
                // Shared-with-me volumes: share root is always a photo or album,
                // never the photo volume root — use that to pick the photo performer.
                let isPhotoVolume = volume.shares.contains { share in
                    share.root is CoreDataPhoto || share.root is CoreDataAlbum
                }
                return !isPhotoVolume
            }
            volumePerformerCache[volumeID] = isFile
            return isFile
        }
    }
}
