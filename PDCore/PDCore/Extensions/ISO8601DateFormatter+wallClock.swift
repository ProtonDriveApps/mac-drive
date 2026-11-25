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

public extension ISO8601DateFormatter {

    /// Time zone encoded in an ISO8601 timestamp (`Z`, `±HH:MM`, or `±HHMM`).
    static func timeZone(fromISO8601 string: String) -> TimeZone? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.uppercased().hasSuffix("Z") {
            return TimeZone(secondsFromGMT: 0)
        }

        if let colonOffset = trimmed.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) {
            return timeZone(fromOffsetString: String(trimmed[colonOffset]))
        }

        if let compactOffset = trimmed.range(of: #"[+-]\d{4}$"#, options: .regularExpression) {
            return timeZone(fromOffsetString: String(trimmed[compactOffset]))
        }

        return nil
    }

    /// Formats the wall-clock time in the offset embedded in `iso8601`, not the device time zone.
    static func localizedWallClockString(
        fromISO8601 iso8601: String?,
        dateStyle: DateFormatter.Style = .short,
        timeStyle: DateFormatter.Style = .short,
        locale: Locale = .current
    ) -> String? {
        guard let iso8601, let date = date(iso8601) else {
            return nil
        }
        let timeZone = timeZone(fromISO8601: iso8601) ?? TimeZone(secondsFromGMT: 0)!
        return localizedWallClockString(
            fromInstant: date,
            timeZone: timeZone,
            dateStyle: dateStyle,
            timeStyle: timeStyle,
            locale: locale
        )
    }

    private static func localizedWallClockString(
        fromInstant date: Date,
        timeZone: TimeZone,
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        formatter.timeZone = timeZone
        formatter.locale = locale
        formatter.doesRelativeDateFormatting = false
        return formatter.string(from: date)
    }

    private static func timeZone(fromOffsetString offset: String) -> TimeZone? {
        let sign: Int = offset.hasPrefix("-") ? -1 : 1
        let digits = offset.filter(\.isNumber)
        guard digits.count == 4 else { return nil }

        let hours = Int(digits.prefix(2)) ?? 0
        let minutes = Int(digits.suffix(2)) ?? 0
        let secondsFromGMT = sign * (hours * 3600 + minutes * 60)
        return TimeZone(secondsFromGMT: secondsFromGMT)
    }
}
