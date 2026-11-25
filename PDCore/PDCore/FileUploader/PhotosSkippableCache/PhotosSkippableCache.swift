// Copyright (c) 2023 Proton AG
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

public protocol PhotosSkippableCache {
    typealias Identifier = PhotoAssetMetadata.iOSPhotos
    /// Sets the number of expected (remaining) files to be backed up
    func setPendingFiles(_ data: [Identifier: Int])
    /// Decrements the number of expected (remaining) files to be backed up
    func decrementPendingFiles(_ data: [Identifier: Int])
    func pendingFiles(identifier: Identifier) -> Int?
    func isSkippable(_ identifier: Identifier) -> Bool
    func checkSkippableStatus(_ identifier: Identifier) -> SkippableStatus
    func clean()
    func cacheCount() -> Int 
    #if DEBUG
    func debugPrint()
    #endif
}

public final class ConcretePhotosSkippableCache: PhotosSkippableCache {

    public init(storage: PhotosSkippableStorage) {
        self.storage = storage
    }
    
    private var storage: PhotosSkippableStorage

    private func prepare(_ identifier: Identifier) -> Identifier {
        identifier.rounded()
    }
    
    /// Sets the number of expected (remaining) files to be backed up
    public func setPendingFiles(_ data: [Identifier: Int]) {
        var result: [Identifier: Int] = [:]
        for (id, value) in data {
            let id = prepare(id)
            result[id] = value
        }
        storage.setPendingFiles(data: result)
    }
    
    /// Decrements the number of expected (remaining) files to be backed up
    public func decrementPendingFiles(_ data: [Identifier: Int]) {
        var result: [Identifier: Int] = [:]
        for (id, filesToDiscount) in data {
            result[prepare(id), default: 0] += filesToDiscount
        }
        storage.decrementPendingFiles(data: result)
    }

    public func pendingFiles(identifier: Identifier) -> Int? {
        let identifier = prepare(identifier)
        return storage[identifier]
    }
    
    public func isSkippable(_ identifier: Identifier) -> Bool {
        let identifier = prepare(identifier)
        let canSkip = storage[identifier] == 0
        #if DEBUG // Creates too much noise
        Log.debug("Check skippable status of \(identifier): " + String(describing: storage[identifier]) + ". Should be 0 for skipping.", domain: .photosProcessing)
        #endif
        return canSkip
    }
    
    public func checkSkippableStatus(_ identifier: Identifier) -> SkippableStatus {
        let identifier = prepare(identifier)
        return storage.checkSkippableStatus(identifier: identifier)
    }

    public func cacheCount() -> Int {
        storage.cacheCount()
    }

    public func clean() {
        storage.clean()
    }

    #if DEBUG
    public func debugPrint() {
        storage.debugPrint()
    }
    #endif
}

extension PhotosSkippableCache {
    public func isSkippable(_ identifier: PhotoIdentifier) -> Bool {
        isSkippable(Identifier(identifier))
    }
    
    public func checkSkippableStatus(_ identifier: PhotoIdentifier) -> SkippableStatus {
        checkSkippableStatus(Identifier(identifier))
    }
    
    public func setPendingFiles(_ data: [PhotoIdentifier: Int]) {
        var result: [Identifier: Int] = [:]
        for (identifier, value) in data {
            result[Identifier(identifier)] = value
        }
        setPendingFiles(result)
    }

    public func decrementPendingFiles(_ data: [PhotoIdentifier: Int]) {
        var result: [Identifier: Int] = [:]
        for (identifier, filesToDiscount) in data {
            // Two identifiers can share one asset, so discounts add up rather than overwrite.
            result[Identifier(identifier), default: 0] += filesToDiscount
        }
        decrementPendingFiles(result)
    }
}

extension PhotoAssetMetadata.iOSPhotos {
    init(_ identifier: PhotoIdentifier) {
        self.init(identifier: identifier.cloudIdentifier, modificationTime: identifier.modifiedDate)
    }
}

public final class BlankPhotosSkippableCache: PhotosSkippableCache {
    public func pendingFiles(identifier: Identifier) -> Int? { 1 }
    public func discard() { }
    public init() { }
    
    public func isSkippable(_ identifier: Identifier) -> Bool {
        false
    }
    public func checkSkippableStatus(_ identifier: Identifier) -> SkippableStatus {
        .newAsset
    }
    public func setPendingFiles(_ data: [Identifier: Int]) {}
    public func decrementPendingFiles(_ data: [Identifier: Int]) {}

    public func clean() {}
    public func cacheCount() -> Int { 0 }
    #if DEBUG
    public func debugPrint() { }
    #endif
}

extension PhotoAssetMetadata.iOSPhotos {
    func rounded() -> Self {
        if let timestamp = modificationTime?.timeIntervalSinceReferenceDate {
            let rounded = TimeInterval(Int(timestamp))
            return Self(identifier: identifier, modificationTime: Date(timeIntervalSinceReferenceDate: rounded))
        } else {
            return self
        }
    }
}
