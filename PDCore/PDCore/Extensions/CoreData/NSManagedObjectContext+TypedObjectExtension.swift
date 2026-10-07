// Copyright (c) 2026 Proton AG
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

import CoreData

extension NSManagedObjectContext {
    public func typedObject<R: NSManagedObject>(id: NSManagedObjectID) throws -> R {
        try (existingObject(with: id) as? R) ?! "Incorrect cast type"
    }
    
    public func typedObject<R: NSManagedObject>(url: URL) throws -> R {
        let id = try persistentStoreCoordinator?.managedObjectID(forURIRepresentation: url) ?! "No object found"
        return try typedObject(id: id)
    }
}
