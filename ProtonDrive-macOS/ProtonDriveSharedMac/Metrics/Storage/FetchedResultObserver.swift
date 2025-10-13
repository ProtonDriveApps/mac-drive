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

import PDCore
import CoreData
import Combine

/// Observes changes made to a DB using both a `NSFetchedResultsController` for process-local
/// changes and listening to `NSNotification.Name.NSPersistentStoreRemoteChange` for remote
/// changes; publishes them mapped to domain objects on `itemPublisher`.
class FetchedResultObserver<DBModel: NSManagedObject & DomainConvertible>: NSObject {
    private let fetchedResultsController: NSFetchedResultsController<DBModel>

    private let subject = PassthroughSubject<[DBModel], Never>()
    var itemPublisher: AnyPublisher<[DBModel.DomainObject], Never> {
        subject
            .map { items in
                items.compactMap {
                    try? $0.toDomain()
                }
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    private var cancellable: AnyCancellable?

    init(
        fetchRequest: NSFetchRequest<DBModel>,
        context: NSManagedObjectContext
    ) {
        Log.trace()

        self.fetchedResultsController = NSFetchedResultsController(
            fetchRequest: fetchRequest,
            managedObjectContext: context,
            sectionNameKeyPath: nil,
            cacheName: nil
        )
        super.init()

        self.cancellable = NotificationCenter.default
            .publisher(for: .NSPersistentStoreRemoteChange)
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                self?.handleStoreRemoteChange($0)
            }
    }

    @objc func handleStoreRemoteChange(_ object: Any?) {
        Task {
            Log.trace()
            try await fetchItems()
        }
    }

    func fetchItems() async throws {
        Log.trace()
        try await fetchedResultsController.managedObjectContext.perform {
            self.fetchedResultsController.managedObjectContext.stalenessInterval = 0
            self.fetchedResultsController.managedObjectContext.refreshAllObjects()
            self.fetchedResultsController.managedObjectContext.stalenessInterval = -1

            try self.fetchedResultsController.performFetch()
            self.didReceiveUpdate(items: self.fetchedResultsController.fetchedObjects ?? [])
        }
    }
    
    // MARK: - Private

    /// Note: always call within the items' managed object context!!!
    private func didReceiveUpdate(items: [DBModel]) {
        subject.send(items)
    }
    
    deinit {
        Log.trace()
    }
}
