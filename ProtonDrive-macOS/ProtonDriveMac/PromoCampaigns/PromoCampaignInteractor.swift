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

struct PromoCampaignConfiguration: Comparable {
    enum BannerIcon {
        case drivePlus
        case discount
        case blackFriday

        var imageName: String {
            switch self {
            case .drivePlus:
                "Promo/ic-drive-plus"
            case .discount:
                "Promo/ic-promo-discount"
            case .blackFriday:
                "Promo/ic-black-friday"
            }
        }
    }

    enum TimeRange: Comparable {
        /// Campaign should only be active while start < date < end
        case limitedTime(start: Date, end: Date)
        /// Campaign should be active after the given date
        case indefinite(after: Date)

        static func < (lhs: TimeRange, rhs: TimeRange) -> Bool {
            switch (lhs, rhs) {
            case (.limitedTime(let lStart, _), .limitedTime(let rStart, _)),
                 (.limitedTime(let lStart, _), .indefinite(let rStart)),
                 (.indefinite(let lStart), .limitedTime(let rStart, _)),
                 (.indefinite(let lStart), .indefinite(let rStart)):
                return lStart < rStart
            }
        }
    }

    struct BannerGradient: Equatable {
        let gradient: Gradient
        let startPoint: UnitPoint
        let endPoint: UnitPoint
    }

    // Figma node 8367:10531, converted for the 360 x 36 banner.
    // Endpoints extend outside the banner to preserve the gradient's angle and spread.
    private static let blackFridayGradient = BannerGradient(
        gradient: Gradient(stops: [
            .init(color: Color(hex: "#FFFAD7"), location: 0),
            .init(color: Color(hex: "#FFC283"), location: 0.586538434),
            .init(color: Color(hex: "#FF8383"), location: 1)
        ]),
        startPoint: UnitPoint(x: 0.311491083, y: -2.109408569),
        endPoint: UnitPoint(x: 0.684211498, y: 3.049922135)
    )

    static let activeCampaigns: [PromoCampaignConfiguration] = [
        PromoCampaignConfiguration(
            campaignId: "bf-26-stage-1",
            timeRange: .limitedTime(
                start: ISO8601DateFormatter().date(from: "2026-11-02T12:00:00+01:00")!,
                end: ISO8601DateFormatter().date(from: "2026-11-16T12:00:00+01:00")!
            ),
            backgroundColor: Color(hex: "#FFFAD7"),
            tintColor: Color(hex: "#1B1340"),
            icon: .blackFriday,
            text: "BLACK FRIDAY",
            resetsPreviousDismissal: true,
            displaysOnStatusBar: true,
            trackingReference: "offer_bf_26_drive_free_unlimited_macos",
            backgroundGradient: blackFridayGradient,
            fontWeight: .semibold
        ),
        PromoCampaignConfiguration(
            campaignId: "bf-26-stage-2",
            timeRange: .limitedTime(
                start: ISO8601DateFormatter().date(from: "2026-11-16T12:00:00+01:00")!,
                end: ISO8601DateFormatter().date(from: "2026-12-01T12:00:00+01:00")!
            ),
            backgroundColor: Color(hex: "#FFFAD7"),
            tintColor: Color(hex: "#1B1340"),
            icon: .blackFriday,
            text: "BLACK FRIDAY",
            resetsPreviousDismissal: true,
            displaysOnStatusBar: true,
            trackingReference: "offer_bf_26_drive_free_plus_macos",
            backgroundGradient: blackFridayGradient,
            fontWeight: .semibold
        ),
        PromoCampaignConfiguration(
            campaignId: "upgrade-drive-plus",
            timeRange: .indefinite(
                after: ISO8601DateFormatter().date(from: "2026-12-01T12:00:00+01:00")!
            ),
            backgroundColor: ColorProvider.Primary,
            tintColor: ColorProvider.White,
            icon: .drivePlus,
            text: "Upgrade to Drive Plus",
            resetsPreviousDismissal: false,
            displaysOnStatusBar: false
        )
    ]

    let campaignId: String
    let timeRange: TimeRange
    let backgroundColor: Color
    let tintColor: Color
    let icon: BannerIcon
    let text: String
    let resetsPreviousDismissal: Bool
    let displaysOnStatusBar: Bool
    var trackingReference: String?
    var backgroundGradient: BannerGradient?
    var fontWeight: Font.Weight = .medium

    static func < (lhs: PromoCampaignConfiguration, rhs: PromoCampaignConfiguration) -> Bool {
        lhs.timeRange < rhs.timeRange
    }
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
    @SettingsStorage(UserDefaults.PromoCampaign.lastSeenCampaignId.rawValue) private var lastSeenCampaign: String?

    private let activeCampaigns: [PromoCampaignConfiguration]
    private var currentlyActiveCampaign = CurrentValueSubject<PromoCampaignConfiguration?, Never>(nil)

    private let dateResource: DateResource

    static let shared = PromoCampaignInteractor()

    init(dateResource: DateResource, activeCampaigns: [PromoCampaignConfiguration]) {
        self.dateResource = dateResource
        self.activeCampaigns = activeCampaigns

        _hasDismissedBanner.configure(with: Constants.appGroup)
        _lastSeenCampaign.configure(with: Constants.appGroup)

        refreshCampaign()
    }

    private convenience init() {
        self.init(
            dateResource: PromoCampaignDateResource(),
            activeCampaigns: PromoCampaignConfiguration.activeCampaigns
        )
    }

    func refreshCampaign(forceResetBannerDismissal: Bool = false) {
        let activeCampaign = getActiveCampaign()

        if forceResetBannerDismissal || shouldResetBannerDismissal(for: activeCampaign) {
            hasDismissedBanner = false
        }

        if hasDismissedBanner == true {
            return currentlyActiveCampaign.send(.none)
        }

        lastSeenCampaign = activeCampaign?.campaignId
        currentlyActiveCampaign.send(activeCampaign)
    }

    func dismissCampaign() {
        hasDismissedBanner = true
        currentlyActiveCampaign.send(.none)
    }

    private func getActiveCampaign() -> PromoCampaignConfiguration? {
        activeCampaigns.sorted().first { campaign in
            let currentDate = dateResource.getDate()

            switch campaign.timeRange {
            case let .limitedTime(start, end):
                return start <= currentDate && currentDate < end
            case let .indefinite(start):
                return start <= currentDate
            }
        }
    }

    private func shouldResetBannerDismissal(for activeCampaign: PromoCampaignConfiguration?) -> Bool {
        guard let activeCampaign, let lastSeenCampaign, hasDismissedBanner == true else {
            return false
        }

        return activeCampaign.resetsPreviousDismissal && activeCampaign.campaignId != lastSeenCampaign
    }
}
