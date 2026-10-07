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
@preconcurrency import PDCore

public enum QuotaLimitReason: Sendable, Equatable {
    case insufficientQuota
    case insufficientSpace
}

public enum UploadKind: Sendable, Equatable {
    case file    // → 1 thumbnail (default)
    case photo   // → 2 thumbnails (default + photo)
}

public struct QuotaExceededError: LocalizedError, Sendable, Equatable {
    public let reason: QuotaLimitReason

    public init(reason: QuotaLimitReason) {
        self.reason = reason
    }

    public var errorDescription: String? {
        switch reason {
        case .insufficientQuota:
            return "Not enough quota available to complete the upload."
        case .insufficientSpace:
            return "Not enough storage space available to complete the upload."
        }
    }
}

/// Global, persistent quota limiter for SDK upload paths, modelled as a state
/// machine. Once the backend returns 200001/200002 the limiter leaves `.open`
/// and gates further uploads using a cached Quota + estimated encrypted size
/// and a throttle window, while self-healing the (often stale) cached quota.
/// An armed state returns to `.open` once the throttle window elapses, so an
/// upload is never permanently blocked.
public actor QuotaLimiter {
    public struct Configuration: Sendable {
        public var throttleWindow: TimeInterval
        /// Minimum gap between self-heal refreshes. Defaults to half the throttle window, and is
        /// capped at the throttle window so a window-expiry restart always re-triggers a heal.
        public var selfHealMinInterval: TimeInterval

        public init(throttleWindow: TimeInterval = 300, selfHealMinInterval: TimeInterval? = nil) {
            self.throttleWindow = throttleWindow
            // Cap at throttleWindow: the restart re-heal relies on selfHealMinInterval ≤ throttleWindow,
            // otherwise a window-expiry restart could skip the heal and never re-fetch a stuck cache.
            self.selfHealMinInterval = min(selfHealMinInterval ?? throttleWindow / 2, throttleWindow)
        }
    }

    public typealias Now = @Sendable () -> Date

    private var storage: QuotaLimiterStorage
    private let quotaResource: QuotaResource
    private let quotaRefresher: QuotaRefreshing
    private let configuration: Configuration
    private let now: Now

    private var selfHealTask: Task<Void, Never>?

    public init(
        storage: QuotaLimiterStorage,
        quotaResource: QuotaResource,
        quotaRefresher: QuotaRefreshing,
        configuration: Configuration = Configuration(),
        now: @escaping Now = { Date() }
    ) {
        self.storage = storage
        self.quotaResource = quotaResource
        self.quotaRefresher = quotaRefresher
        self.configuration = configuration
        self.now = now
    }

    public nonisolated func runOperation<T>(
        clearFileSize: Int64?,
        kind: UploadKind,
        _ operation: () async throws -> T
    ) async throws -> T {
        switch await gate(clearFileSize: clearFileSize, kind: kind) {
        case .block(let reason):
            throw QuotaExceededError(reason: reason)
        case .run:
            do {
                return try await operation()
            } catch {
                if let reason = error.quotaLimitReason {
                    await recordQuotaError(reason: reason)
                    throw QuotaExceededError(reason: reason)
                }
                throw error
            }
        }
    }

    // MARK: - Gating

    private enum Gate {
        case run
        case block(QuotaLimitReason)
    }

    private func gate(clearFileSize: Int64?, kind: UploadKind) -> Gate {
        // Throttle window elapsed in an armed state → restart the whole cycle from open,
        // so the next quota error re-arms and re-triggers a self-heal.
        if storage.state != .open, !isWithinThrottleWindow(lastErrorAt: storage.lastErrorAt) {
            resetToOpen()
        }
        switch storage.state {
        case .open:
            return .run
        case .windowEstimate, .selfHealed:
            if estimateFits(clearFileSize: clearFileSize, kind: kind) {
                return .run
            }
            return .block(storage.lastReason ?? .insufficientSpace)
        case .windowOnly:
            // Sticky within the window: ignore the estimate, block until the window elapses.
            return .block(storage.lastReason ?? .insufficientSpace)
        }
    }

    /// Fail-closed: an unknown quota or file size counts as "does not fit".
    private func estimateFits(clearFileSize: Int64?, kind: UploadKind) -> Bool {
        guard let clearFileSize, let cachedQuota = quotaResource.getQuota() else {
            return false
        }
        let estimatedRemoteSize = QuotaLimiter.estimatedEncryptedSize(forClearSize: clearFileSize, kind: kind)
        return Int64(cachedQuota.available) >= estimatedRemoteSize
    }

    // MARK: - Transitions

    /// Throttle window elapsed while armed: drop back to open so the cycle restarts
    /// (fresh re-probe, re-arm, and a new self-heal on the next quota error).
    private func resetToOpen() {
        Log.info("QuotaLimiter throttle window elapsed, restarting from \(storage.state)", domain: .sdk)
        cancelSelfHeal()
        storage.state = .open
        storage.lastErrorAt = nil
        storage.lastReason = nil
    }

    private func recordQuotaError(reason: QuotaLimitReason) {
        let previous = storage.state
        storage.lastErrorAt = now()
        storage.lastReason = reason

        switch previous {
        case .open:
            storage.state = .windowEstimate
            Log.info("QuotaLimiter armed: open → windowEstimate", domain: .sdk)
            triggerSelfHeal()
        case .windowEstimate:
            if selfHealTask != nil {
                // Heal in flight: keep trusting the estimate until it corrects the cache.
                Log.info("QuotaLimiter quota error in windowEstimate (heal in flight), refreshing window", domain: .sdk)
            } else {
                // A let-through upload failed with no heal running (skipped/rate-limited), so the
                // estimate is proven stale-positive with nothing to correct it → stop trusting it.
                storage.state = .windowOnly
                Log.info("QuotaLimiter estimate stale-positive, no heal in flight: windowEstimate → windowOnly", domain: .sdk)
            }
        case .selfHealed:
            storage.state = .windowOnly
            Log.info("QuotaLimiter estimate wrong after self-heal: selfHealed → windowOnly", domain: .sdk)
        case .windowOnly:
            Log.info("QuotaLimiter quota error in windowOnly, refreshing window", domain: .sdk)
        }
    }

    // MARK: - Self-heal

    /// Fire-and-forget refresh of the cached quota, rate-limited to at most once
    /// per `selfHealMinInterval` and never overlapping. On completion, if still in
    /// `windowEstimate`, advance to `selfHealed` (refresh succeeded) or `windowOnly`
    /// (refresh failed — the estimate can no longer be trusted).
    private func triggerSelfHeal() {
        guard selfHealTask == nil else { return }
        if let lastRefreshAt = storage.lastRefreshAt,
           now().timeIntervalSince(lastRefreshAt) < configuration.selfHealMinInterval {
            return
        }
        storage.lastRefreshAt = now()
        let refresher = quotaRefresher
        selfHealTask = Task { [weak self] in
            let refreshed = await refresher.refreshQuota()
            // If the limiter returned to open (success or window-expiry restart) the task was
            // cancelled and its handle cleared; don't apply a stale result to a new cycle.
            guard !Task.isCancelled else { return }
            await self?.selfHealDidComplete(refreshed: refreshed)
        }
    }

    /// Cancels and forgets any in-flight self-heal. Called when returning to `.open` so the next
    /// `open → windowEstimate` starts a fresh refresh even if the previous one stalled and never returned.
    private func cancelSelfHeal() {
        selfHealTask?.cancel()
        selfHealTask = nil
    }

    private func selfHealDidComplete(refreshed: Bool) {
        selfHealTask = nil
        guard storage.state == .windowEstimate else { return }
        if refreshed {
            storage.state = .selfHealed
            Log.info("QuotaLimiter self-heal complete: windowEstimate → selfHealed", domain: .sdk)
        } else {
            // Refresh failed: the cache is still unverified, so stop trusting the estimate.
            storage.state = .windowOnly
            Log.info("QuotaLimiter self-heal failed, distrusting estimate: windowEstimate → windowOnly", domain: .sdk)
        }
    }

    /// Test hook: awaits the in-flight self-heal task, if any.
    func awaitSelfHealForTesting() async {
        await selfHealTask?.value
    }

    private func isWithinThrottleWindow(lastErrorAt: Date?) -> Bool {
        guard let lastErrorAt else { return false }
        return now().timeIntervalSince(lastErrorAt) < configuration.throttleWindow
    }
}

// MARK: - Encrypted size estimation

extension QuotaLimiter {
    /// Worst-case encryption overhead per block.
    static let maxBlockEncryptionOverhead: Int64 = 56

    /// Estimates the encrypted (remote) size for a clear file of `clearFileSize` bytes.
    static func estimatedEncryptedSize(forClearSize clearFileSize: Int64, kind: UploadKind) -> Int64 {
        let blockSize = Int64(Constants.maxBlockSize)
        let blockCount = (clearFileSize + blockSize - 1) / blockSize
        let thumbnailWeight: Int
        switch kind {
        case .file:
            thumbnailWeight = Constants.thumbnailMaxWeight
        case .photo:
            thumbnailWeight = Constants.thumbnailMaxWeight + Constants.photoThumbnailMaxWeight
        }
        return clearFileSize
             + blockCount * maxBlockEncryptionOverhead
             + Int64(thumbnailWeight)
    }
}

// MARK: - Composable limiter adapter

struct QuotaLimiterWithContext: UploadLimiter {
    let limiter: QuotaLimiter
    let clearFileSize: Int64?
    let kind: UploadKind

    func runOperation<T>(_ operation: () async throws -> T) async throws -> T {
        try await limiter.runOperation(clearFileSize: clearFileSize, kind: kind, operation)
    }
}

extension QuotaLimiter {
    public nonisolated func withContext(clearFileSize: Int64?, kind: UploadKind) -> any UploadLimiter {
        QuotaLimiterWithContext(limiter: self, clearFileSize: clearFileSize, kind: kind)
    }
}
