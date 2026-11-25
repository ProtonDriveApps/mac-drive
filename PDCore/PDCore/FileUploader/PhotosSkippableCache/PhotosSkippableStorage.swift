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

public protocol PhotosSkippableStorage {
    typealias Identifier = PhotoAssetMetadata.iOSPhotos
    subscript(index: Identifier) -> Int? { get set }

    func checkSkippableStatus(identifier: Identifier) -> SkippableStatus
    /// Overwrites the pending-file count of each identifier. Pass 0 to mark an asset fully
    /// skippable. To account for individual files finishing, use `decrementPendingFiles`.
    func setPendingFiles(data: [Identifier: Int])
    /// Subtracts the given number of files from each identifier's pending count, clamped at 0.
    func decrementPendingFiles(data: [Identifier: Int])
    func clean()
    func cacheCount() -> Int
    #if DEBUG
    func debugPrint()
    #endif
}

public enum SkippableStatus {
    /// Recorded identifier, all files are uploaded
    case skippable
    /// Has pending upload tasks
    case hasPendingUpload
    /// New created asset
    case newAsset
    /// Need to compare adjustmentTimestamp with modification date
    case needsDoubleCheck
}

public class UserDefaultsPhotosSkippableStorage: PhotosSkippableStorage {
    typealias Store = [String: Int]
    private static let delimiter = "@"
    private static let reportedIdentifiersLimit = 5
    
    @SettingsStorage(SettingsStorageKey.photosSkippableCacheKey.value) private var store: Store?
    private let queue = DispatchQueue(label: "SkippableStorage", qos: .userInteractive, attributes: .concurrent)
    private var inMemorySet: Set<InMemoryData> = Set()
    
    public init(suite: SettingsStorageSuite = .standard) {
        _store.configure(with: suite)
        queue.async(flags: .barrier) {
            self.inMemorySet = self.loadSetFromStore()
        }
    }
    
    public subscript(index: Identifier) -> Int? {
        get {
            queue.sync {
                let tmp = InMemoryData(identifier: index)
                guard let cached = inMemorySet.first(where: { $0 == tmp }) else { return nil }
                return cached.fileNeedsToBeUploaded(on: index.modificationTime)
            }
        }
        set {
            queue.async(flags: .barrier) { [weak self] in
                let tmp = InMemoryData(identifier: index, fileNeedsToBeUploaded: newValue)
                self?.inMemorySet.mergeableInsert(tmp)
                self?.saveSetToStore(self!.inMemorySet)
            }
        }
    }
    
    public func setPendingFiles(data: [Identifier: Int]) {
        guard !data.isEmpty else { return }
        queue.async(flags: .barrier) { [weak self] in
            for (identifier, value) in data {
                Log.debug("Skippable status of \(identifier) set to \(value)", domain: .photosProcessing)
                let tmp = InMemoryData(
                    cloudIdentifier: identifier.identifier,
                    data: [identifier.modificationTime: value]
                )
                self?.inMemorySet.mergeableInsert(tmp)
            }
            self?.saveSetToStore(self!.inMemorySet)
        }
    }
    
    public func decrementPendingFiles(data: [Identifier: Int]) {
        guard !data.isEmpty else { return }
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            var unknownIdentifiers: [String] = []
            for (identifier, decrementBy) in data {
                let probe = InMemoryData(identifier: identifier)
                let current = self.inMemorySet.first(where: { $0 == probe })?
                    .fileNeedsToBeUploaded(on: identifier.modificationTime)
                guard let current else {
                    // Nothing recorded (cache cleaned, fresh install, or the asset was modified
                    // since it was recorded). Callers subtract files they are done with, so the
                    // remainder is 0 — storing `decrementBy` would claim that many files are still
                    // pending and keep the asset out of `.skippable` forever.
                    unknownIdentifiers.append(identifier.identifier)
                    Log.debug("Identifier \(identifier) not found in skippable table, recorded as skippable", domain: .photosProcessing)
                    self.inMemorySet.mergeableInsert(
                        InMemoryData(cloudIdentifier: identifier.identifier, data: [identifier.modificationTime: 0])
                    )
                    continue
                }
                let remaining = max(0, current - decrementBy)
                Log.debug("Skippable status of \(identifier) updated to \(remaining)", domain: .photosProcessing)
                self.inMemorySet.mergeableInsert(
                    InMemoryData(cloudIdentifier: identifier.identifier, data: [identifier.modificationTime: remaining])
                )
            }
            if !unknownIdentifiers.isEmpty {
                // One report for the whole batch. Expected after the cache is cleaned, but a spike
                // means keys are drifting between what the pipeline records and what the uploader
                // reports, which is what keeps assets from ever becoming skippable.
                var context = LogContext(unknownIdentifiers.count, forKey: "count")
                // Capped: send just a handful of identifiers. Sentry would trim them anyway.
                context["cloudIdentifiers"] = unknownIdentifiers.prefix(Self.reportedIdentifiersLimit).joined(separator: ", ")
                context["trimmedListOfIdentifiers"] = unknownIdentifiers.count > Self.reportedIdentifiersLimit
                Log.error("Identifiers not found in skippable table", domain: .photosProcessing, context: context)
            }
            // Single write for the whole batch.
            self.saveSetToStore(self.inMemorySet)
        }
    }

    public func checkSkippableStatus(identifier: Identifier) -> SkippableStatus {
        let tmp = InMemoryData(identifier: identifier)
        
        return queue.sync {
            guard let cached = self.inMemorySet.first(where: { $0 == tmp }) else { return .newAsset }
            if let value = cached.fileNeedsToBeUploaded(on: identifier.modificationTime) {
                return value == 0 ? .skippable : .hasPendingUpload
            }
            return .needsDoubleCheck
        }
    }

    public func clean() {
        store = [:]
        queue.sync {
            self.inMemorySet = self.loadSetFromStore()
        }
    }

    public func cacheCount() -> Int {
        queue.sync {
            inMemorySet.count
        }
    }

    #if DEBUG
    public func debugPrint() {
        for data in inMemorySet {
            Log.debug(String(describing: data.export()), domain: .photosProcessing)
        }
    }
    #endif

    private func loadSetFromStore() -> Set<InMemoryData> {
        var set: Set<InMemoryData> = Set()
        
        for (string, value) in store ?? [:] {
            var parts = string.components(separatedBy: Self.delimiter)
            
            let identifier = parts.removeFirst()
            
            var date: Date?
            if let time = parts.last, let double = TimeInterval(time) {
                date = Date(timeIntervalSinceReferenceDate: double)
            }
            let data: InMemoryData = .init(cloudIdentifier: identifier, data: [date: value])
            set.mergeableInsert(data)
        }
        return set
    }
    
    private func saveSetToStore(_ set: Set<InMemoryData>) {
        var dict = Store()
        for data in set {
            let exported = data.export()
            dict.merge(exported, uniquingKeysWith: { $1 })
        }
        self.store = dict
    }
}

final class InMemoryData: Hashable {
    private static let delimiter = "@"
    let cloudIdentifier: String
    /// [Modification date: file needs to be uploaded]
    private(set) var data: [Date?: Int] = [:]
    
    init(cloudIdentifier: String, data: [Date?: Int]) {
        self.cloudIdentifier = cloudIdentifier
        self.data = data
    }
    
    init(identifier: PhotoAssetMetadata.iOSPhotos, fileNeedsToBeUploaded: Int? = nil) {
        self.cloudIdentifier = identifier.identifier
        if let fileNeedsToBeUploaded {
            self.data = [identifier.modificationTime: fileNeedsToBeUploaded]
        } else {
            self.data = [:]
        }
    }
    
    func fileNeedsToBeUploaded(on date: Date?) -> Int? {
        data[date]
    }
    
    func merge(other: [Date?: Int]) {
        data.merge(other) { $1 }
    }
    
    func export() -> [String: Int] {
        var result: [String: Int] = [:]
        for (date, value) in data {
            var time = ""
            if let double = date?.timeIntervalSinceReferenceDate {
                time = "\(double)"
            }
            let string = cloudIdentifier + Self.delimiter + time
            result[string] = value
        }
        return result
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(cloudIdentifier)
    }
    
    static func == (lhs: InMemoryData, rhs: InMemoryData) -> Bool {
        lhs.cloudIdentifier == rhs.cloudIdentifier
    }
}

extension Set where Element == InMemoryData {
    mutating func mergeableInsert(_ element: InMemoryData) {
        if let cached = first(where: { $0 == element }) {
            cached.merge(other: element.data)
        } else {
            insert(element)
        }
    }
}
