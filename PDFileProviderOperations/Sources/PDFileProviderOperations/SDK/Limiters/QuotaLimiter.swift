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

/// Global, persistent quota limiter for SDK upload paths. Once the backend
/// returns 200001/200002, the limiter "arms" and uses a cached Quota +
/// estimated encrypted size to short-circuit further uploads that won't fit,
/// for a period of throttle window after the last quota error.
public actor QuotaLimiter {
    public struct Configuration: Sendable {
        public var throttleWindow: TimeInterval

        public init(throttleWindow: TimeInterval = 300) {
            self.throttleWindow = throttleWindow
        }
    }

    public typealias Now = @Sendable () -> Date

    private var storage: QuotaLimiterStorage
    private let quotaResource: QuotaResource
    private let configuration: Configuration
    private let now: Now

    public init(
        storage: QuotaLimiterStorage,
        quotaResource: QuotaResource,
        configuration: Configuration = Configuration(),
        now: @escaping Now = { Date() }
    ) {
        self.storage = storage
        self.quotaResource = quotaResource
        self.configuration = configuration
        self.now = now
    }
    
    public nonisolated func runOperation<T>(
        clearFileSize: Int64?,
        kind: UploadKind,
        _ operation: () async throws -> T
    ) async throws -> T {
        let snap = await snapshot()

        // if not armed, skip any quota or window checks. arm on error
        if !snap.armed {
            return try await run(operation, onQuotaError: { await arm(reason: $0) })
        }

        let estimatedRemoteSize = clearFileSize.map {
            QuotaLimiter.estimatedEncryptedSize(forClearSize: $0, kind: kind)
        }

        let estimateFits: Bool
        if let cachedQuota = snap.cachedQuota, let estimatedRemoteSize {
            estimateFits = cachedQuota.available >= estimatedRemoteSize
        } else {
            estimateFits = true
        }

        // don't check the window if the estimate fits, always try the API. update timestamp on quota error
        if estimateFits {
            return try await run(operation, onQuotaError: { await refreshLastError(reason: $0) })
        }

        // Estimate doesn't fit; respect throttle window before going to the API again.
        if await isWithinThrottleWindow(lastErrorAt: snap.lastErrorAt) {
            throw QuotaExceededError(reason: snap.lastReason ?? .insufficientSpace)
        }

        // estimate doesn't fit but the throttle window expired, try API again
        return try await run(operation, onQuotaError: { await refreshLastError(reason: $0) })
    }

    private nonisolated func run<T>(
        _ operation: () async throws -> T,
        onQuotaError: (QuotaLimitReason) async -> Void
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            if let reason = error.quotaLimitReason {
                await onQuotaError(reason)
                throw QuotaExceededError(reason: reason)
            }
            throw error
        }
    }

    private struct Snapshot: Sendable {
        var armed: Bool
        var lastErrorAt: Date?
        var lastReason: QuotaLimitReason?
        var cachedQuota: Quota?
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            armed: storage.armed,
            lastErrorAt: storage.lastErrorAt,
            lastReason: storage.lastReason,
            cachedQuota: quotaResource.getQuota()
        )
    }

    private func arm(reason: QuotaLimitReason) {
        storage.armed = true
        storage.lastErrorAt = now()
        storage.lastReason = reason
    }

    private func refreshLastError(reason: QuotaLimitReason) {
        storage.lastErrorAt = now()
        storage.lastReason = reason
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
