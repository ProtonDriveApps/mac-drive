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
import PDFileProvider

/// Per-folder, in-memory rate limiter for parents that the backend has rejected
/// with TOO_MANY_CHILDREN (200300) or NESTING_TOO_DEEP (200301).
public actor FolderRateLimiter: FolderRateLimiting {
    public typealias Now = @Sendable () -> Date
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private struct Entry {
        var blockedUntil: Date
        var attemptCount: Int
        var reason: FolderLimitReason
        var snapshot: Int?
    }

    private let now: Now
    private let sleep: Sleep
    private let folderStateProvider: FolderStateProvider
    private let baseBackoff: TimeInterval
    private let multiplier: Double
    private let maxBackoff: TimeInterval
    private let immediateFailThreshold: TimeInterval

    private var entries: [NodeIdentifier: Entry] = [:]

    public init(
        folderStateProvider: FolderStateProvider,
        baseBackoff: TimeInterval = 60,
        multiplier: Double = 2.0,
        maxBackoff: TimeInterval = 3600,
        immediateFailThreshold: TimeInterval = 10,
        now: @escaping Now = { Date.now },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.folderStateProvider = folderStateProvider
        self.baseBackoff = baseBackoff
        self.multiplier = multiplier
        self.maxBackoff = maxBackoff
        self.immediateFailThreshold = immediateFailThreshold
        self.now = now
        self.sleep = sleep
    }

    /// Wait for the folder's window to clear, run the operation, then either
    /// `clear` on success or `flag` on a folder-limit failure.
    public nonisolated func runOperation<T>(
        parent: NodeIdentifier,
        in moc: NSManagedObjectContext,
        _ operation: () async throws -> T
    ) async throws -> T {
        try await waitOrFail(folder: parent, in: moc)
        do {
            let result = try await operation()
            await clear(folder: parent)
            return result
        } catch {
            if let reason = error.folderLimitReason {
                let remainingDelay = await flag(folder: parent, reason: reason, in: moc)
                throw FolderRateLimitedError(
                    folder: parent, remainingDelay: remainingDelay, reason: reason
                )
            }
            throw error
        }
    }

    func waitOrFail(folder: NodeIdentifier, in moc: NSManagedObjectContext) async throws {
        guard let entry = entries[folder] else { return }
        let remaining = entry.blockedUntil.timeIntervalSince(now())
        guard remaining > 0 else { return }

        if remaining <= immediateFailThreshold {
            try await sleep(.seconds(remaining))
            return
        }

        if let snapshot = entry.snapshot,
           await snapshotChanged(reason: entry.reason, snapshot: snapshot, folder: folder, in: moc) {
            return
        }

        throw FolderRateLimitedError(folder: folder, remainingDelay: remaining, reason: entry.reason)
    }

    @discardableResult
    func flag(
        folder: NodeIdentifier, reason: FolderLimitReason, in moc: NSManagedObjectContext
    ) async -> TimeInterval {
        let attemptCount = (entries[folder]?.attemptCount ?? 0) + 1
        let backoff = min(maxBackoff, baseBackoff * pow(multiplier, Double(attemptCount - 1)))
        let blockedUntil = now().addingTimeInterval(backoff)
        // Write attempt count and blockedUntil before suspending so concurrent
        // failures observe an updated count and grow the backoff correctly.
        entries[folder] = Entry(blockedUntil: blockedUntil, attemptCount: attemptCount, reason: reason, snapshot: nil)
        let snapshot = await currentSnapshot(reason: reason, folder: folder, in: moc)
        // Optional chain is intentional: if clear(folder:) was called from another task
        // while suspended above, the entry is already gone and the write is a no-op.
        entries[folder]?.snapshot = snapshot
        return blockedUntil.timeIntervalSince(now())
    }

    func clear(folder: NodeIdentifier) {
        entries.removeValue(forKey: folder)
    }

    func remainingDelay(for folder: NodeIdentifier) -> TimeInterval? {
        guard let entry = entries[folder] else { return nil }
        let remaining = entry.blockedUntil.timeIntervalSince(now())
        return remaining > 0 ? remaining : nil
    }

    private func currentSnapshot(reason: FolderLimitReason, folder: NodeIdentifier, in moc: NSManagedObjectContext) async -> Int? {
        switch reason {
        case .tooManyChildren:
            guard let count = await folderStateProvider.childrenCount(for: folder, in: moc) else { return nil }
            return count
        case .nestingTooDeep:
            guard let depth = await folderStateProvider.depth(for: folder, in: moc) else { return nil }
            return depth
        }
    }

    /// Returns true only when local state has improved (count/depth went down) — an increase
    /// would still hit the same backend limit and re-flag the folder, so we keep blocking.
    private func snapshotChanged(
        reason: FolderLimitReason,
        snapshot: Int,
        folder: NodeIdentifier,
        in moc: NSManagedObjectContext
    ) async -> Bool {
        switch reason {
        case .tooManyChildren:
            guard let current = await folderStateProvider.childrenCount(for: folder, in: moc) else { return false }
            return current < snapshot
        case .nestingTooDeep:
            guard let current = await folderStateProvider.depth(for: folder, in: moc) else { return false }
            return current < snapshot
        }
    }
}

struct FolderRateLimiterWithContext: @unchecked Sendable, UploadLimiter {
    let limiter: FolderRateLimiter
    let parent: NodeIdentifier
    let moc: NSManagedObjectContext

    func runOperation<T>(_ operation: () async throws -> T) async throws -> T {
        try await limiter.runOperation(parent: parent, in: moc, operation)
    }
}

extension FolderRateLimiter {
    public nonisolated func withContext(parent: NodeIdentifier, in moc: NSManagedObjectContext) -> any UploadLimiter {
        FolderRateLimiterWithContext(limiter: self, parent: parent, moc: moc)
    }
}

public struct FolderRateLimitedError: LocalizedError, Sendable {
    public let folder: NodeIdentifier
    public let remainingDelay: TimeInterval
    public let reason: FolderLimitReason

    public init(folder: NodeIdentifier, remainingDelay: TimeInterval, reason: FolderLimitReason) {
        self.folder = folder
        self.remainingDelay = remainingDelay
        self.reason = reason
    }

    public var errorDescription: String? {
        switch reason {
        case .tooManyChildren:
            return "Limit of items in folder reached. Organize items into subfolders to continue syncing."
        case .nestingTooDeep:
            return "Limit of folder nesting reached. Reduce the nesting to continue syncing."
        }
    }
}
