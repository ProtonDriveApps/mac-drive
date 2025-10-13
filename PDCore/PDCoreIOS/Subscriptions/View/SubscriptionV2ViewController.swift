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

import UIKit
import PDCore
import ProtonCorePaymentsV2
import ProtonCorePaymentsUIV2
import ProtonCoreServices
import ProtonCoreUIFoundations
import PDUIComponents
import PDLocalization
import PDClient

final class SubscriptionV2ViewController: UIViewController {

    private let payments: PaymentsV2
    private let credentialProvider: CredentialProvider
    private let configuration: PDClient.APIService.Configuration

    init(
        payments: PaymentsV2,
        credentialProvider: CredentialProvider,
        configuration: PDClient.APIService.Configuration
    ) {
        self.payments = payments
        self.credentialProvider = credentialProvider
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setLeadingTitleView(title: Localization.menu_text_subscription)
        view.backgroundColor = ColorProvider.BackgroundNorm

        Task {
            await showPlans()
        }
    }

    @MainActor
    private func showPlans() async {
        do {
            if !TransactionsObserver.shared.isON {
                try await startTransactionsObserver()
            }
            let credential = try credentialProvider.getCredential()
            let paymentsViewController = try payments.availablePlansView(
                sessionID: credential.UID,
                accessToken: credential.accessToken,
                appVersion: configuration.clientVersion,
                doh: configuration.environment.doh
            )
            add(paymentsViewController)
        } catch {
            Log.error(error: error, domain: .subscriptions)
        }
    }

    private func startTransactionsObserver() async throws {
        let credential = try credentialProvider.getCredential()
        let configuration = TransactionsObserverConfiguration(
            sessionID: credential.UID,
            authToken: credential.accessToken,
            appVersion: configuration.clientVersion,
            doh: configuration.environment.doh
        )
        TransactionsObserver.shared.setConfiguration(configuration)
        try await TransactionsObserver.shared.start()
    }
}
