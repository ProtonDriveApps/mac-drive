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

@MainActor
protocol FullResyncApplicationStateObserverProtocol  {
    func performFullResync() async throws
    func updateFullResyncItemsCount(_ count: Int)
    func proceedToDomainReenumeration() async throws
    func completeFullResync(hasFileProviderResponded: Bool)
    func cancelFullResync() async throws
    func finishFullResync()
    func fullResyncErrored(message: String)
}

extension ApplicationEventObserver: FullResyncApplicationStateObserverProtocol {}

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
            Log.debug("Not performing resync because it was not interrupted", domain: .application)
            return
        }
        let startTime = Date.now
        fullResyncMonitor = FullResyncMonitor()
        performWithLogging { [weak self] in
            try await self?.applicationEventObserver.performFullResync()
            await self?.fullResyncService.start(
                onNodeRefreshed: { [weak self] refreshedNodesCount in
                    self?.applicationEventObserver.updateFullResyncItemsCount(refreshedNodesCount)
                },
                onFinish: { [weak self] in
                    self?.fullResyncMonitor?.reportFullResyncEnd(status: .completed)
                    // the error is not caught here by design — it should be propagated to fullResyncService which handles it internally
                    try await self?.onFullResyncFinished(startTime: startTime)
                },
                onCancel: { [weak self] in
                    self?.fullResyncMonitor?.reportFullResyncEnd(status: .cancelled)
                    performWithLogging {
                        try await self?.applicationEventObserver.cancelFullResync()
                    }
                },
                onError: { [weak self] error in
                    self?.fullResyncMonitor?.reportFullResyncEnd(status: .failed)
                    self?.applicationEventObserver.fullResyncErrored(message: error.localizedDescription)
                }
            )
        }
    }

    @MainActor
    private func onFullResyncFinished(startTime: Date) async throws {
        try await applicationEventObserver.proceedToDomainReenumeration()
        shouldReenumerateItems = true
        // workingSetEnumerationInProgress is stored in shared user defaults
        // and used for communication with file provider extension, hence observation
        workingSetEnumerationInProgress = true
        observationCenter.addObserver(self, of: \.workingSetEnumerationInProgress) { [weak self] value in
            if value == false {
                Task { [weak self] in
                    // a delay to give some time for the file provider extension to pick up more changes through `fetchItem` calls
                    // the number is arbitrary, because we don't know if the extension will make these calls at all nor how long they'll take
                    try? await Task.sleep(for: .seconds(15))
                    guard let self else { return }
                    self.completeFullResync(hasFileProviderResponded: true, startTime: startTime)
                }
            }
        }
        do {
            try await domainOperationsService.signalEnumerator()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                // if the file provider has not responed within 15 seconds, we're gonna assume it won't response at all
                guard let self else { return }
                self.completeFullResync(hasFileProviderResponded: false, startTime: startTime)
            }
        } catch {
            Log.error("Signal enumerator failed \(error.localizedDescription)", domain: .application)
            self.completeFullResync(hasFileProviderResponded: false, startTime: startTime)
        }
    }
    
    @MainActor
    private func completeFullResync(hasFileProviderResponded: Bool, startTime: Date) {
        guard workingSetEnumerationInProgress != nil else { return }
        observationCenter.removeObserver(self)
        workingSetEnumerationInProgress = nil
        Log.info("Full resync completed in \(Date().timeIntervalSince(startTime)) seconds",
                 domain: .application,
                 sendToSentryIfPossible: true)
        applicationEventObserver.completeFullResync(hasFileProviderResponded: hasFileProviderResponded)
        menuBarCoordinator?.showMenuProgramatically()
    }
    
    func finishFullResync() {
        performWithLogging { [weak self] in
            await self?.applicationEventObserver.finishFullResync()
        }
    }

    func retryFullResync() {
        performFullResync()
        fullResyncMonitor?.retryHappened()
    }
    
    func cancelFullResync() {
        fullResyncService.cancel()
    }
    
    func abortFullResync() {
        fullResyncService.abort()
        performWithLogging { [weak self] in
            try await self?.applicationEventObserver.cancelFullResync()
        }
    }
}
