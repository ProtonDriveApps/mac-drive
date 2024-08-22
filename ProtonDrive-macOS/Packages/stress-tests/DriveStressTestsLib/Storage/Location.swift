//
//  Location.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 22/01/2024.
//

import Foundation

public protocol Location: Equatable, CustomStringConvertible {
    static var kind: LocationKind { get }
    var storage: Storage<Self> { get }
    init(storage: Storage<Self>)
}

public extension Location {
    static func ==(lhs: Self, rhs: Self) -> Bool {
        return lhs.storage.path == rhs.storage.path
    }

    var description: String {
        let typeName = String(describing: type(of: self))
        return "\(typeName)(name: \(name), path: \(path))"
    }

    /// The path of this location, relative to the root of the file system.
    var path: String {
        return storage.path
    }

    /// A URL representation of the location's `path`.
    var url: URL {
        return URL(fileURLWithPath: path)
    }

    /// The name of the location, including any `extension`.
    var name: String {
        return url.pathComponents.last!
    }

    var parent: Folder? {
        return storage.makeParentPath(for: path).flatMap {
            try? Folder(path: $0)
        }
    }

    /// The date when the item at this location was created.
    /// Only returns `nil` in case the item has now been deleted.
    var creationDate: Date? {
        return storage.attributes[.creationDate] as? Date
    }

    /// The date when the item at this location was last modified.
    /// Only returns `nil` in case the item has now been deleted.
    var modificationDate: Date? {
        return storage.attributes[.modificationDate] as? Date
    }

    /// Initialize an instance of an existing location at a given path.
    /// - parameter path: The absolute path of the location.
    /// - throws: `LocationError` if the item couldn't be found.
    init(path: String) throws {
        try self.init(storage: Storage(
            path: path,
            fileManager: .default
        ))
    }

    /// Move this location to a new parent folder
    /// - parameter newParent: The folder to move this item to.
    /// - throws: `LocationError` if the location couldn't be moved.
    func move(to newParent: Folder) throws {
        try storage.move(
            to: newParent.path + name,
            errorReasonProvider: LocationErrorReason.moveFailed
        )
    }

}
