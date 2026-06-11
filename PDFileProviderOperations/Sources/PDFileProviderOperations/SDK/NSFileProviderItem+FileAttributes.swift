// Copyright (c) 2025 Proton AG
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

import FileProvider
import PDSDKCore

extension FileAttributes {
    
    init(url: URL, itemTemplate: NSFileProviderItem) {
        // TODO: we don't use itemTemplate.documentSize because it was causing the size mismatch for SDK on package files
        let size = url.fileSize ?? 0
        let creationDate = itemTemplate.creationDate??.timeIntervalSince1970
                        ?? itemTemplate.contentModificationDate??.timeIntervalSince1970
                        ?? Date.now.timeIntervalSince1970
        let modificationDate = itemTemplate.contentModificationDate??.timeIntervalSince1970 ?? creationDate
        self.init(
            fileSize: Int64(size),
            creationDate: Date(timeIntervalSince1970: creationDate),
            modificationDate: Date(timeIntervalSince1970: modificationDate)
        )
    }
}
