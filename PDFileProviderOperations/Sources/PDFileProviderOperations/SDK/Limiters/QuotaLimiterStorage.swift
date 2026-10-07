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

/// The limiter's persisted state. `.open` is the un-armed fast path; the other
/// states gate uploads after the backend returned a quota error. Every state
/// recovers to `.open` on a successful upload.
public enum QuotaLimiterState: Int, Sendable, Equatable {
    /// No gating; run every upload. Arms on a quota error.
    case open = 0
    /// Armed, cache may be stale: trust the estimate, else the throttle window.
    case windowEstimate = 1
    /// Armed, cache refreshed: trust the (now fresh) estimate, else the window.
    case selfHealed = 2
    /// Armed, ignore the estimate entirely: gate purely on the throttle window.
    case windowOnly = 3
}

public protocol QuotaLimiterStorage: Sendable {
    var state: QuotaLimiterState { get set }
    var lastErrorAt: Date? { get set }
    var lastReason: QuotaLimitReason? { get set }
    var lastRefreshAt: Date? { get set }
}

public final class UserDefaultsQuotaLimiterStorage: QuotaLimiterStorage, @unchecked Sendable {
    @SettingsStorage("quotaLimiter.stateCode") private var stateCodeValue: Int?
    @SettingsStorage("quotaLimiter.lastErrorAt") private var lastErrorAtValue: Date?
    @SettingsStorage("quotaLimiter.lastReasonCode") private var lastReasonCodeValue: Int?
    @SettingsStorage("quotaLimiter.lastRefreshAt") private var lastRefreshAtValue: Date?

    public init(suite: SettingsStorageSuite = .group(named: Constants.appGroup)) {
        _stateCodeValue.configure(with: suite)
        _lastErrorAtValue.configure(with: suite)
        _lastReasonCodeValue.configure(with: suite)
        _lastRefreshAtValue.configure(with: suite)
    }

    public var state: QuotaLimiterState {
        get { stateCodeValue.flatMap(QuotaLimiterState.init(rawValue:)) ?? .open }
        set { stateCodeValue = newValue.rawValue }
    }

    public var lastErrorAt: Date? {
        get { lastErrorAtValue }
        set { lastErrorAtValue = newValue }
    }

    public var lastReason: QuotaLimitReason? {
        get {
            switch lastReasonCodeValue {
            case ResponseCode.insufficientQuota.rawValue: return .insufficientQuota
            case ResponseCode.insufficientSpace.rawValue: return .insufficientSpace
            default: return nil
            }
        }
        set {
            switch newValue {
            case .insufficientQuota: lastReasonCodeValue = ResponseCode.insufficientQuota.rawValue
            case .insufficientSpace: lastReasonCodeValue = ResponseCode.insufficientSpace.rawValue
            case nil: lastReasonCodeValue = nil
            }
        }
    }

    public var lastRefreshAt: Date? {
        get { lastRefreshAtValue }
        set { lastRefreshAtValue = newValue }
    }
}

// Used in tests
public final class InMemoryQuotaLimiterStorage: QuotaLimiterStorage, @unchecked Sendable {
    public var state: QuotaLimiterState
    public var lastErrorAt: Date?
    public var lastReason: QuotaLimitReason?
    public var lastRefreshAt: Date?

    public init(
        state: QuotaLimiterState = .open,
        lastErrorAt: Date? = nil,
        lastReason: QuotaLimitReason? = nil,
        lastRefreshAt: Date? = nil
    ) {
        self.state = state
        self.lastErrorAt = lastErrorAt
        self.lastReason = lastReason
        self.lastRefreshAt = lastRefreshAt
    }
}
