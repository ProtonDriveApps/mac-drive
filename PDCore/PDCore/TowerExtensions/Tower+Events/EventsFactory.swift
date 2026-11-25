// Copyright (c) 2024 Proton AG
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
import PMEventsManager
import ProtonCoreServices

struct EventsFactory {

    #if os(macOS)
    func makeLegacyConveyor(tower: Tower) -> EventsConveyor {
        return LegacyEventsConveyor(
            storage: tower.eventStorageManager,
            referenceStorage: LegacyEventsReferenceStorage(suite: tower.storageSuite)
        )
    }
    #endif

    func makeEventsLoop(tower: Tower, conveyor: EventsConveyor, volumeId: String) -> DriveEventsLoop {
        Log.trace()
        let processor = DriveEventsLoopProcessor(
            volumeID: volumeId,
            cloudSlot: tower.cloudSlot,
            conveyor: conveyor,
            storage: tower.storage
        )
        return DriveEventsLoop(
            volumeID: volumeId,
            cloudSlot: tower.cloudSlot,
            processor: processor,
            conveyor: conveyor,
            observers: tower.eventObservers,
            mode: tower.eventProcessingMode,
            eventsSystemManager: tower
        )
    }

    func makeSingleVolumeTimingController(interval: Double) -> EventLoopsTimingController {
        // Legacy events system
        SingleVolumeEventLoopsTimingController(interval: interval)
    }

    // swiftlint:disable:next function_parameter_count
    func makeCoreEventsSystem(
        appGroup: SettingsStorageSuite,
        sessionVault: SessionVault,
        generalSettings: GeneralSettings,
        paymentsSecureStorage: PaymentsSecureStorage,
        network: APIService,
        timingController: EventLoopsTimingController,
        contactAdapter: ContactStorage,
        entitlementsManager: EntitlementsManagerProtocol
    ) -> EventPeriodicScheduler<GeneralEventsLoopWithProcessor, DriveEventsLoop> {
        let processor = GeneralEventsLoopProcessor(
            sessionVault: sessionVault,
            generalSettings: generalSettings,
            paymentsVault: paymentsSecureStorage,
            contactVault: contactAdapter,
            entitlementsManager: entitlementsManager
        )
        let generalEventsLoop = GeneralEventsLoop(
            apiService: network,
            processor: processor,
            userDefaults: appGroup.userDefaults,
            logError: {
                Log.error(error: $0, domain: .events)
            }
        )
        return EventPeriodicScheduler<GeneralEventsLoopWithProcessor, DriveEventsLoop>(
            generalLoop: generalEventsLoop,
            timingController: timingController
        )
    }
}
