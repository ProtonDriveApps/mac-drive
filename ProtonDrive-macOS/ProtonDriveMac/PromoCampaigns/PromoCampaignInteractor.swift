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
import ProtonCoreUIFoundations
import SwiftUI
import PDCore
import Combine

struct PromoCampaignConfiguration {
    enum BannerIcon {
        case drivePlus
        case discount

        var imageName: String {
            switch self {
            case .drivePlus:
                "Promo/ic-drive-plus"
            case .discount:
                "Promo/ic-promo-discount"
            }
        }
    }

    enum TimeRange {
        /// Campaign should only be active while start < date < end
        case limitedTime(start: Date, end: Date)
        /// Campaign should be active after the given date
        case indefinite(after: Date)
        /// Campaign should always be active (useful for testing!)
        case always
    }

    fileprivate static let activeCampaigns: [PromoCampaignConfiguration] = [
        PromoCampaignConfiguration(
            timeRange: .limitedTime(
                start: Date(timeIntervalSinceReferenceDate: 783860400), // 2025-11-03 12:00 CET
                end: Date(timeIntervalSinceReferenceDate: 785156400) // 2025-11-18 12:00 CET
            ),
            backgroundColor: Color(hex: "#D8FF00"),
            tintColor: Color(hex: "#291C5D"),
            icon: .discount,
            text: "Black Friday: 50% off"
        ),
        PromoCampaignConfiguration(
            timeRange: .limitedTime(
                start: Date(timeIntervalSinceReferenceDate: 785156400), // 2025-11-18 12:00 CET
                end: Date(timeIntervalSinceReferenceDate: 786452400) // 2025-12-03 12:00 CET
            ),
            backgroundColor: Color(hex: "#D8FF00"),
            tintColor: Color(hex: "#291C5D"),
            icon: .discount,
            text: "Black Friday: 80% off"
        ),
        PromoCampaignConfiguration(
            timeRange: .indefinite(
                after: Date(timeIntervalSinceReferenceDate: 786452400) // 2025-12-03 12:00 CET
            ),
            backgroundColor: ColorProvider.Primary,
            tintColor: ColorProvider.White,
            icon: .drivePlus,
            text: "Upgrade to Drive Plus"
        )
    ]

    let timeRange: TimeRange
    let backgroundColor: Color
    let tintColor: Color
    let icon: BannerIcon
    let text: String
}

protocol PromoCampaignInteractorProtocol {
    var activeCampaign: AnyPublisher<PromoCampaignConfiguration?, Never> { get }

    func dismissCampaign()
}

final class PromoCampaignInteractor: PromoCampaignInteractorProtocol {
    var activeCampaign: AnyPublisher<PromoCampaignConfiguration?, Never> {
        currentlyActiveCampaign.eraseToAnyPublisher()
    }

    @SettingsStorage(UserDefaults.PromoCampaign.hasDismissedBanner.rawValue) private var hasDismissedBanner: Bool?
    private var currentlyActiveCampaign = CurrentValueSubject<PromoCampaignConfiguration?, Never>(nil)

    private let dateResource: DateResource

    static let shared = PromoCampaignInteractor()

    init(
        dateResource: DateResource
    ) {
        self.dateResource = dateResource

        _hasDismissedBanner.configure(with: Constants.appGroup)

        refreshCampaign()
    }

    private convenience init() {
        self.init(dateResource: PromoCampaignDateResource())
    }

    func refreshCampaign(resetBannerDismissal: Bool = false) {
        if resetBannerDismissal {
            hasDismissedBanner = false
        }

        guard (hasDismissedBanner ?? false) == false else {
            currentlyActiveCampaign.send(.none)
            return
        }

        let activeCampaign = getActiveCampaign()
        currentlyActiveCampaign.send(activeCampaign)
    }

    func dismissCampaign() {
        hasDismissedBanner = true
        currentlyActiveCampaign.send(.none)
    }

    private func getActiveCampaign() -> PromoCampaignConfiguration? {
        PromoCampaignConfiguration.activeCampaigns.first { campaign in
            let currentDate = dateResource.getDate()

            switch campaign.timeRange {
            case let .limitedTime(start, end):
                return start <= currentDate && currentDate < end
            case let .indefinite(start):
                return start <= currentDate
            case .always:
                return true
            }
        }
    }
}
