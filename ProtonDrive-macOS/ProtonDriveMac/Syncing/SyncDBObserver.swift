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

import Combine
import CoreData
import SwiftUI
import PDCore
import PDFileProvider

/// Monitors changes made to the Sync DB by the File Provider and propagates them to `ApplicationState`.
final class SyncDBObserver: ObservableObject {

    @ObservedObject private(set) var state: ApplicationState

    private var syncStorageManager: SyncStorageManager?
    private var syncStateDelegate: SyncStateDelegate
    private var syncDBFetchedResultObserver: SyncDBFetchedResultObserver?
    private var testRunner: TestRunner?

    private var cancellables: Set<AnyCancellable> = []

#if DEBUG
    /// Counts how many times the context is saved, to enable detecting when it happens too much.
    static var updateCounter = 0
#endif

    init(
        state: ApplicationState,
        syncStorageManager: SyncStorageManager?,
        eventsProcessor: EventsSystemManager,
        domainOperationsService: DomainOperationsService,
        testRunner: TestRunner?
    ) {
        Log.trace()

        self.state = state
        self.syncStorageManager = syncStorageManager

        self.syncStateDelegate = SyncStateDelegate(eventsProcessor: eventsProcessor,
                                                   domainOperationsService: domainOperationsService)

        self.syncStorageManager?.cleanUpOnLaunch()

        self.testRunner = testRunner
    }

    deinit {
        Log.trace()
        stopSyncMonitoring()
    }

    // MARK: - Observing

    func startSyncMonitoring(
    ) {
        Log.trace()
        setUpObservers()
    }

    public func stopSyncMonitoring() {
        Log.trace()
        syncDBFetchedResultObserver = nil
        cancellables.removeAll()
    }

    private func setUpObservers() {
        Log.trace()

        subscribeToCoreDataUpdates(context: syncStorageManager!.backgroundContext)
    }

    func subscribeToCoreDataUpdates(context: NSManagedObjectContext) {
        let fetchRequest = SyncItem.fetchRequest()
        fetchRequest.fetchLimit = Constants.syncItemListLimit
        fetchRequest.predicate = syncHistoryPredicate()
        fetchRequest.sortDescriptors = [
            NSSortDescriptor(key: "sortOrder", ascending: false), // Sort by syncItemState.sortOrder
            NSSortDescriptor(key: "progress", ascending: false), // Items closest to completion first...
            NSSortDescriptor(key: "modificationTime", ascending: false), // Newer items first
            NSSortDescriptor(key: "location", ascending: true) // ...and sorted by path, so that the order is deterministic.
        ]

        syncDBFetchedResultObserver = SyncDBFetchedResultObserver(fetchRequest: fetchRequest, context: context)

        syncDBFetchedResultObserver?.syncItemPublisher
            .receive(on: RunLoop.main)
            .sink { [unowned self] items in
                Log.trace("syncDBObserver?.syncItemPublisher received \(items.count) item(s).")
                guard let syncStorageManager else {
                    Log.error("Missing syncStorageManager", domain: .syncing)
                    return
                }
                state.items = items
                state.lastSyncTime = syncStorageManager.lastSyncTime()
                
                state.isEnumerating = syncStorageManager.countEnumerationsInProgress() > 0
                if let itemEnumerationProgress = syncStorageManager.itemEnumerationProgress {
                    state.itemEnumerationProgress = itemEnumerationProgress
                } else {
                    state.itemEnumerationProgress = ""
                }

                state.isSyncing = syncStorageManager.countSyncsInProgress() > 0

                if !state.isSyncing {
                    ElapsedTimeService.updateElapsedTime(state: state)
                }
                Log.trace("Syncing: \(state.isSyncing), \(state.formattedTimeSinceLastSync)")

                state.errorCount = syncStorageManager.countSyncErrors()
                state.deleteCount = syncStorageManager.countFinishedDeletions()
#if DEBUG
                Self.updateCounter += 1
                let updateCounterDescription = "updates so far: \(Self.updateCounter)"
#else
                let updateCounterDescription = ""
#endif

                testRunner?.writeSyncStateProperties(state)

                Log.debug("SyncDBObserver core data update: \(items.count) items, errorCount \(state.errorCount), \(updateCounterDescription)", domain: .syncing)
            }
            .store(in: &cancellables)

        if let testRunner {
            state.$throttledItems
                .sink { [unowned self] in
                    self.testRunner?.writeSyncStateItems($0)
                }
                .store(in: &cancellables)
        }

        Task {
            try await fetchItems()
        }
    }

    private func syncHistoryPredicate() -> NSPredicate {
        var predicates = [NSPredicate]()

        if !RuntimeConfiguration.shared.includeItemEnumerationSummaryInTrayApp {
            let excludeItemEnumerationSummary = NSPredicate(
                format: "NOT (fileProviderOperationRaw == %d AND id == %@)",
                FileProviderOperation.enumerateItems.rawValue,
                ItemEnumerationObserver.enumerationSyncItemIdentifier)
            predicates.append(excludeItemEnumerationSummary)
        }

        if !RuntimeConfiguration.shared.includeItemEnumerationDetailsInTrayApp {
            let excludeItemEnumerationDetails = NSPredicate(
                format: "NOT (fileProviderOperationRaw == %d AND id != %@)",
                FileProviderOperation.enumerateItems.rawValue,
                ItemEnumerationObserver.enumerationSyncItemIdentifier)
            predicates.append(excludeItemEnumerationDetails)
        }

        if !RuntimeConfiguration.shared.includeChangeEnumerationSummaryInTrayApp {
            let excludeChangeEnumerationSummary = NSPredicate(
                format: "NOT (fileProviderOperationRaw == %d AND id == %@)",
                FileProviderOperation.enumerateChanges.rawValue,
                ChangeEnumerationObserver.enumerationSyncItemIdentifier)
            predicates.append(excludeChangeEnumerationSummary)
        }

        if !RuntimeConfiguration.shared.includeChangeEnumerationDetailsInTrayApp {
            let excludeChangeEnumerationDetails = NSPredicate(
                format: "NOT (fileProviderOperationRaw == %d AND id != %@)",
                FileProviderOperation.enumerateChanges.rawValue,
                ChangeEnumerationObserver.enumerationSyncItemIdentifier)
            predicates.append(excludeChangeEnumerationDetails)
        }

        let enumerationPredicates = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        let errorPredicate = NSPredicate(format: "stateRaw == %d", SyncItemState.errored.rawValue)
        let interimPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [enumerationPredicates, errorPredicate])

        let excludeHiddenPredicate = NSPredicate(format: "sortOrder => 0")
        let finalPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [interimPredicate, excludeHiddenPredicate])

        Log.trace("Fetching \(finalPredicate.description)")
        return finalPredicate
    }

    func fetchItems() async throws {
        try await syncDBFetchedResultObserver?.fetchItems()
    }

    func cleanUpErrors() {
        Log.trace()
        syncStorageManager?.cleanUpErrors()
    }

    // MARK: - SyncStateDelegate

    public func updateSyncState(paused: Bool, offline: Bool, fullResyncInProgress: Bool) async throws {
        Log.trace()
        try await syncStateDelegate.updateState(paused: paused, offline: offline, fullResyncInProgress: fullResyncInProgress)
        syncStorageManager?.cleanUpOnPause()
    }
}
