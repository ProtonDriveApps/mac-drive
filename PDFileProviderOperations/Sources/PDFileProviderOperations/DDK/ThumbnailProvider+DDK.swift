// Copyright (c) 2024 Proton AG
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

import CoreImage
import PDCore

extension ThumbnailProvider {
    func compress(image: CGImage, maxThumbnailWeight: Int, isCancelled: () -> Bool) throws -> (imageData: Data, quality: Double) {
        for quality in [1.0, 0.7, 0.4, 0.2, 0.1, 0] {
            guard !isCancelled() else { throw ThumbnailGenerationError.cancelled }
            guard let compressed = try compress(image: image, quality: quality, maxThumbnailWeight: maxThumbnailWeight) else { continue }
            return (imageData: compressed, quality: quality)
        }
        throw ThumbnailGenerationError.invalidSizeThumbnail
    }

    private func compress(image: CGImage, quality: Double, maxThumbnailWeight: Int) throws -> Data? {
        guard let compressed = image.jpegData(compressionQuality: quality) else {
            throw ThumbnailGenerationError.compression
        }
        guard compressed.count <= maxThumbnailWeight else { return nil }
        return compressed
    }

    func thumbnailData(fileUrl: URL) -> Data? {
        if let thumbnail = getThumbnail(from: fileUrl, ofSize: PDCore.Constants.defaultThumbnailMaxSize) {
            return try? compress(image: thumbnail, maxThumbnailWeight: PDCore.Constants.thumbnailMaxWeight,
                                                            isCancelled: { Task.isCancelled }).imageData
        }
        return nil
    }
}
