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

public protocol InterruptedPhotoUploadsRepository: Sendable {
    func getUploadIDs() -> Set<UUID>
    func setUploadIDs(_ uploadIDs: Set<UUID>)
    func contains(uploadID: UUID) -> Bool
    func insert(uploadID: UUID)
    func remove(uploadID: UUID)
}

public final class UserDefaultsInterruptedPhotoUploadsRepository: InterruptedPhotoUploadsRepository, @unchecked Sendable {
    private static let lock = NSLock()
    @SettingsStorage(SettingsStorageKey.interruptedPhotoUploadsKey.value) private var store: [String]?

    public init(suite: SettingsStorageSuite) {
        _store.configure(with: suite)
    }

    public func getUploadIDs() -> Set<UUID> {
        Self.lock.withLock { readUploadIDs() }
    }

    public func setUploadIDs(_ uploadIDs: Set<UUID>) {
        Self.lock.withLock { write(uploadIDs) }
    }

    public func contains(uploadID: UUID) -> Bool {
        Self.lock.withLock { readUploadIDs().contains(uploadID) }
    }

    public func insert(uploadID: UUID) {
        Self.lock.withLock {
            var uploadIDs = readUploadIDs()
            guard uploadIDs.insert(uploadID).inserted else { return }
            write(uploadIDs)
        }
    }

    public func remove(uploadID: UUID) {
        Self.lock.withLock {
            var uploadIDs = readUploadIDs()
            guard uploadIDs.remove(uploadID) != nil else { return }
            write(uploadIDs)
        }
    }

    private func readUploadIDs() -> Set<UUID> {
        Set((store ?? []).compactMap(UUID.init(uuidString:)))
    }

    private func write(_ uploadIDs: Set<UUID>) {
        store = uploadIDs.isEmpty ? nil : uploadIDs.map(\.uuidString)
    }
}
