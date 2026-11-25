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

// TODO: Route EnumeratorWithChanges.report(for:) through enqueueWrite once the DM-897 branch has
// landed. It is the last direct SyncItem writer still using a raw Task; deferred here only to keep
// EnumeratorWithChanges.swift conflict-free with that in-flight branch.

import Foundation

public extension SyncStorageManager {

    func enqueueWrite(for id: String, _ operation: @escaping @Sendable () async -> Void) {
        enqueueWrite(for: [id], operation)
    }

    /// Orders the write after all earlier writes and before all later writes that share any of its IDs.
    func enqueueWrite(for ids: [String], _ operation: @escaping @Sendable () async -> Void) {
        let ids = Array(Set(ids))
        writeChainLock.lock()
        defer { writeChainLock.unlock() }
        let previous = ids.compactMap { writeChains[$0] }
        let token = UUID()
        let task = Task {
            for task in previous {
                await task.value
            }
            await operation()
            self.completeWrite(for: ids, token: token)
        }
        for id in ids {
            writeChainTokens[id] = token
            writeChains[id] = task
        }
    }

    private func completeWrite(for ids: [String], token: UUID) {
        writeChainLock.lock()
        defer { writeChainLock.unlock() }
        // A newer write may have taken over only some of these IDs.
        for id in ids where writeChainTokens[id] == token {
            writeChains[id] = nil
            writeChainTokens[id] = nil
        }
    }
}

#if DEBUG
public extension SyncStorageManager {

    /// Awaits all currently enqueued write chains. Test-only.
    func drainWriteChains() async {
        let tasks = activeWriteTasks
        for task in tasks {
            await task.value
        }
    }
    
    var activeWriteTasks: [Task<Void, Never>] {
        writeChainLock.lock()
        defer { writeChainLock.unlock() }
        return Array(writeChains.values)
    }

    var activeWriteChainCount: Int {
        writeChainLock.lock()
        defer { writeChainLock.unlock() }
        return writeChains.count
    }
}
#endif
