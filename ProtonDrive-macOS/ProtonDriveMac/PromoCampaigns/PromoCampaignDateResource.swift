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

import Foundation
import PDCore

final class PromoCampaignDateResource: DateResource {
#if HAS_QA_FEATURES
    @SettingsStorage(QASettingsConstants.overrideDateForPromoCampaign) var overrideDateForPromoCampaign: String?

    private let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.timeZone = .init(identifier: "CET")

        return dateFormatter
    }()
#endif

    private let underlyingDateResource: DateResource

    init(dateResource: DateResource) {
        self.underlyingDateResource = dateResource
    }

    convenience init() {
        self.init(dateResource: PlatformCurrentDateResource())
    }

    func getDate() -> Date {
#if HAS_QA_FEATURES
        guard let overrideDateForPromoCampaign else {
            return underlyingDateResource.getDate()
        }

        guard let parsedDate = dateFormatter.date(from: overrideDateForPromoCampaign) else {
            Log.trace("Possible misconfiguration: have a string for promo date override, but it's not parseable as a date.")
            return underlyingDateResource.getDate()
        }

        return parsedDate
#else
        return underlyingDateResource.getDate()
#endif
    }

    func getPastDate() -> Date {
        underlyingDateResource.getPastDate()
    }
}
