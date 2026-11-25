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

import Photos

public extension String {
    /// The stable part of a `PHAsset.localIdentifier`.
    ///
    /// A local identifier has the form `<uuid>/L0/001`, and only the leading UUID identifies the
    /// asset — the trailing fragment can differ between two fetches of the same asset (for example
    /// between a plain fetch and a `fetchAssets(withBurstIdentifier:)` fetch). Comparing the whole
    /// string therefore reports the same asset as two different ones.
    var photoAssetIdentity: String {
        guard let separatorIndex = firstIndex(of: "/") else { return self }
        return String(self[startIndex..<separatorIndex])
    }
}

public extension PHAsset {
    var assetIdentity: String {
        localIdentifier.photoAssetIdentity
    }
}
