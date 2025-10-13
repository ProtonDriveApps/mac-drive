// Copyright (c) 2023 Proton AG
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

import PDCore
import ProtonCorePayments
import ProtonCoreServices

/// Fetches the user's subscription plan and checks whether it is upgradeable, as defined in Constants.nonUpgradeablePlanNames.
class SubscriptionService {

    let apiService: ProtonCoreServices.APIService

    init(apiService: ProtonCoreServices.APIService) {
        self.apiService = apiService
    }

    func fetchSubscription(state: ApplicationState) {

        /// Dummy implementation required by `Payments`.
        final class DummyAlertManager: AlertManagerProtocol {
            var title: String?
            var confirmButtonTitle: String?
            var cancelButtonTitle: String?
            var message: String = ""
            var confirmButtonStyle: ProtonCorePayments.AlertActionStyle = .default
            var cancelButtonStyle: ProtonCorePayments.AlertActionStyle = .cancel
            func showAlert(confirmAction: ProtonCorePayments.ActionCallback, cancelAction: ProtonCorePayments.ActionCallback) {
            }
        }

        /// Dummy implementation required by `Payments`.
        final class DummyPaymentsStorage: ServicePlanDataStorage {
            var servicePlansDetails: [Plan]?
            var defaultPlanDetails: Plan?
            var currentSubscription: ProtonCorePayments.Subscription?
            var credits: Credits?
            var paymentMethods: [PaymentMethod]?
            var paymentsBackendStatusAcceptsIAP = false
            var iapSupportStatus: ProtonCorePayments.IAPSupportStatus = .disabled(localizedReason: nil)
        }

        let payments = Payments(
            inAppPurchaseIdentifiers: [],
            apiService: apiService,
            localStorage: DummyPaymentsStorage(),
            alertManager: DummyAlertManager(),
            reportBugAlertHandler: nil
        )

        switch payments.planService {
        case .left(let planService):
            planService.updateCurrentSubscription {
                Log.debug(planService.currentSubscription.debugDescription, domain: .application)
                let planNames = planService.currentSubscription?.planDetails?
                    .filter { $0.isAPrimaryPlan }
                    .compactMap { $0.name } ?? []
                let currentPlanIsNonUpgradeable = Constants.nonUpgradeablePlanNames.contains(planNames.first ?? "")
                state.setCanGetMoreStorage(!currentPlanIsNonUpgradeable)
            } failure: { error in
                Log.error("SubscriptionService.fetchSubscription", error: error, domain: .application)
            }
        case .right(let planDataSource):
            Task {
                do {
                    try await planDataSource.fetchCurrentPlan()
                    let planName = planDataSource.currentPlan?.subscriptions.first?.name ?? InAppPurchasePlan.freePlanName
                    let currentPlanIsNonUpgradeable = Constants.nonUpgradeablePlanNames.contains(planName)
                    state.setCanGetMoreStorage(!currentPlanIsNonUpgradeable)
                } catch {
                    Log.error(error: error, domain: .application)
                }
            }
        }
    }
}
