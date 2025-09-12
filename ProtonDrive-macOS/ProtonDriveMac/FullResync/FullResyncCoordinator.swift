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

protocol FullResyncApplicationStateObserverProtocol  {
    @MainActor func fullResyncStarted() async throws
    @MainActor func fullResyncItemCountUpdated(_ count: Int)
    @MainActor func fullResyncReenumerationStarted() async throws
    @MainActor func fullResyncCompleted(hasFileProviderResponded: Bool)
    @MainActor func fullResyncFinished()
    @MainActor func fullResyncErrored(message: String)
    @MainActor func fullResyncCancelled() async throws

    var state: ApplicationState { get }
    func waitUntilEnumerationHasBegunAndEnded() async throws
}

extension ApplicationEventObserver: FullResyncApplicationStateObserverProtocol {}

/// Coordinates the flow of information between all the moving parts involved in a Resync: about a Resync between the domain, menu bar, and application state.
final class FullResyncCoordinator {
    
    @SettingsStorage(UserDefaults.FileProvider.shouldReenumerateItemsKey.rawValue) var shouldReenumerateItems: Bool?
    @SettingsStorage(UserDefaults.FileProvider.workingSetEnumerationInProgressKey.rawValue) var workingSetEnumerationInProgress: Bool?
    
    private let applicationEventObserver: FullResyncApplicationStateObserverProtocol
    private let fullResyncService: FullResyncServiceProtocol
    private let domainOperationsService: DomainOperationsServiceProtocol
    private let observationCenter: UserDefaultsObservationCenter
    private let menuBarCoordinator: MenuBarCoordinator?
    
    private var fullResyncMonitor: FullResyncMonitor?
    
    convenience init(applicationEventObserver: FullResyncApplicationStateObserverProtocol,
                     domainOperationsService: DomainOperationsServiceProtocol,
                     menuBarCoordinator: MenuBarCoordinator?,
                     tower: Tower) {
        self.init(applicationEventObserver: applicationEventObserver,
                  fullResyncService: FullResyncService(tower: tower),
                  domainOperationsService: domainOperationsService,
                  menuBarCoordinator: menuBarCoordinator)
    }

    init(applicationEventObserver: FullResyncApplicationStateObserverProtocol,
         fullResyncService: FullResyncServiceProtocol,
         domainOperationsService: DomainOperationsServiceProtocol,
         menuBarCoordinator: MenuBarCoordinator?) {
        Log.trace()

        self.applicationEventObserver = applicationEventObserver
        self.fullResyncService = fullResyncService
        self.domainOperationsService = domainOperationsService
        self.menuBarCoordinator = menuBarCoordinator

        self.observationCenter = UserDefaultsObservationCenter(userDefaults: Constants.appGroup.userDefaults)

        _shouldReenumerateItems.configure(with: Constants.appGroup)
        _workingSetEnumerationInProgress.configure(with: Constants.appGroup)

        workingSetEnumerationInProgress = nil
    }
    
    deinit {
        observationCenter.removeObserver(self)
    }

    func performFullResync(onlyIfPreviouslyInterrupted: Bool = false) {
        if onlyIfPreviouslyInterrupted && !fullResyncService.previousRunWasInterrupted {
            Log.debug("Not performing resync because it was not interrupted", domain: .resyncing)
            return
        }
        
        Log.trace()
        let startTime = Date.now
        fullResyncMonitor = FullResyncMonitor()
        performWithLogging { [weak self] in
            try await self?.applicationEventObserver.fullResyncStarted()
            await self?.fullResyncService.start(
                onNodesRefreshed: { refreshedNodesCount in
                    self?.applicationEventObserver.fullResyncItemCountUpdated(refreshedNodesCount)
                },
                onDoneResyncing: {
                    performWithLogging {
                        try await self?.applicationEventObserver.fullResyncReenumerationStarted()
                    }

                    // the error is not caught here by design — it should be propagated to fullResyncService which handles it internally
                    try await self?.reenumerateAfterResyncing(startTime: startTime)
                },
                onCompleted: {
                    self?.fullResyncMonitor?.reportFullResyncEnd(status: .completed)
                },
                onCancelled: {
                    self?.fullResyncMonitor?.reportFullResyncEnd(status: .cancelled)
                    performWithLogging {
                        try await self?.applicationEventObserver.fullResyncCancelled()
                    }
                },
                onErrored: { error in
                    self?.fullResyncMonitor?.reportFullResyncEnd(status: .failed)
                    self?.applicationEventObserver.fullResyncErrored(message: error.localizedDescription)
                }
            )
        }
    }

    @MainActor
    private func reenumerateAfterResyncing(startTime: Date) async throws {
        Log.trace()
        performWithLogging { [weak self] in
            try await self?.applicationEventObserver.fullResyncReenumerationStarted()
        }

        shouldReenumerateItems = true

        // workingSetEnumerationInProgress is stored in shared user defaults
        // and used for communication with file provider extension, hence observation
        // to detect when the file provider sets the value back to false.
        workingSetEnumerationInProgress = true

        do {
            try await domainOperationsService.signalEnumerator()

            try await applicationEventObserver.waitUntilEnumerationHasBegunAndEnded()

            self.completeFullResync(hasFileProviderResponded: true, startTime: startTime)
        } catch {
            Log.error("Signal enumerator failed \(error.localizedDescription)", domain: .resyncing)
            self.completeFullResync(hasFileProviderResponded: false, startTime: startTime)
        }
    }

    @MainActor
    private func completeFullResync(hasFileProviderResponded: Bool, startTime: Date) {
        Log.trace(workingSetEnumerationInProgress?.description ?? "n/a")
        guard workingSetEnumerationInProgress != nil else { return }
        observationCenter.removeObserver(self)
        workingSetEnumerationInProgress = nil
        Log.info("Full resync completed in \(Date().timeIntervalSince(startTime)) seconds",
                 domain: .resyncing,
                 sendToSentryIfPossible: true)
        applicationEventObserver.fullResyncCompleted(hasFileProviderResponded: hasFileProviderResponded)
        menuBarCoordinator?.showMenuProgramatically()
    }

    // MARK: - UserActionsDelegate

    func finishFullResync() {
        Log.trace()
        performWithLogging { [weak self] in
            await self?.applicationEventObserver.fullResyncFinished()
        }
    }

    func retryFullResync() {
        Log.trace()
        fullResyncMonitor?.retryHappened()
        performFullResync()
    }
    
    func cancelFullResync() {
        Log.trace()

        fullResyncService.cancel()

        performWithLogging { [weak self] in
            try await self?.applicationEventObserver.fullResyncCancelled()
        }
    }
}
