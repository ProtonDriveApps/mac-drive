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

public protocol QuotaLimiterStorage: Sendable {
    var armed: Bool { get set }
    var lastErrorAt: Date? { get set }
    var lastReason: QuotaLimitReason? { get set }
}

public final class UserDefaultsQuotaLimiterStorage: QuotaLimiterStorage, @unchecked Sendable {
    @SettingsStorage("quotaLimiter.armed") private var armedValue: Bool?
    @SettingsStorage("quotaLimiter.lastErrorAt") private var lastErrorAtValue: Date?
    @SettingsStorage("quotaLimiter.lastReasonCode") private var lastReasonCodeValue: Int?

    public init(suite: SettingsStorageSuite = .group(named: Constants.appGroup)) {
        _armedValue.configure(with: suite)
        _lastErrorAtValue.configure(with: suite)
        _lastReasonCodeValue.configure(with: suite)
    }

    public var armed: Bool {
        get { armedValue ?? false }
        set { armedValue = newValue }
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
}

// Used in tests
public final class InMemoryQuotaLimiterStorage: QuotaLimiterStorage, @unchecked Sendable {
    public var armed: Bool
    public var lastErrorAt: Date?
    public var lastReason: QuotaLimitReason?

    public init(armed: Bool = false, lastErrorAt: Date? = nil, lastReason: QuotaLimitReason? = nil) {
        self.armed = armed
        self.lastErrorAt = lastErrorAt
        self.lastReason = lastReason
    }
}
