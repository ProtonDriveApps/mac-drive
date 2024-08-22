//
//  LocationManager.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 22/01/2024.
//

import Foundation

/// https://www.swiftbysundell.com/articles/working-with-files-and-folders-in-swift/
public final class Storage<LocationType: Location> {
    
    private(set) var path: String
    let fileManager: FileManager
    
    init(path: String, fileManager: FileManager) throws {
        self.path = path
        self.fileManager = fileManager
    }
}

extension Storage {
    
    var attributes: [FileAttributeKey : Any] {
        return (try? fileManager.attributesOfItem(atPath: path)) ?? [:]
    }
    
    func makeParentPath(for path: String) -> String? {
        guard path != "/" else { return nil }
        let url = URL(fileURLWithPath: path)
        let components = url.pathComponents.dropFirst().dropLast()
        guard !components.isEmpty else { return "/" }
        return "/" + components.joined(separator: "/") + "/"
    }

    func move(to newPath: String,
              errorReasonProvider: (Error) -> LocationErrorReason) throws {
        do {
            try fileManager.moveItem(atPath: path, toPath: newPath)

            switch LocationType.kind {
            case .file:
                path = newPath
            case .folder:
                path = newPath.appendingSuffixIfNeeded("/")
            }
        } catch {
            throw LocationError(path: path, reason: errorReasonProvider(error))
        }
    }
}

// MARK: - Files

public struct File: Location {
    public let storage: Storage<File>

    public init(storage: Storage<File>) {
        self.storage = storage
    }
}

public extension File {
    static var kind: LocationKind {
        return .file
    }
}

// MARK: - Folder

public struct Folder: Location {
    public let storage: Storage<Folder>
    
    public init(storage: Storage<Folder>) {
        self.storage = storage
    }
}

public extension Folder {
    static var kind: LocationKind {
        return .folder
    }

    /// A sequence containing all of this folder's subfolders. Initially
    /// non-recursive, use `recursive` on the returned sequence to change that.
    var subfolders: ChildSequence<Folder> {
        return storage.makeChildSequence()
    }

    /// A sequence containing all of this folder's files. Initially
    /// non-recursive, use `recursive` on the returned sequence to change that.
    var files: ChildSequence<File> {
        return storage.makeChildSequence()
    }

    /// Return a subfolder at a given path within this folder.
    /// - parameter path: A relative path within this folder.
    /// - throws: `LocationError` if the subfolder couldn't be found.
    func subfolder(at path: String) throws -> Folder {
        return try storage.subfolder(at: path)
    }

    /// Return a subfolder with a given name.
    /// - parameter name: The name of the subfolder to return.
    /// - throws: `LocationError` if the subfolder couldn't be found.
    func subfolder(named name: String) throws -> Folder {
        return try storage.subfolder(at: name)
    }

    /// Return whether this folder contains a subfolder at a given path.
    /// - parameter path: The relative path of the subfolder to look for.
    func containsSubfolder(at path: String) -> Bool {
        return (try? subfolder(at: path)) != nil
    }

    /// Return whether this folder contains a subfolder with a given name.
    /// - parameter name: The name of the subfolder to look for.
    func containsSubfolder(named name: String) -> Bool {
        return (try? subfolder(named: name)) != nil
    }

    /// Create a new subfolder at a given path within this folder. In case
    /// the intermediate folders between this folder and the new one don't
    /// exist, those will be created as well. This method throws an error
    /// if a folder already exists at the given path.
    /// - parameter path: The relative path of the subfolder to create.
    /// - throws: `WriteError` if the operation couldn't be completed.
    @discardableResult
    func createSubfolder(at path: String) throws -> Folder {
        return try storage.createSubfolder(at: path)
    }

    @discardableResult
    func createSubfolder(at parent: URL, named name: String) throws -> Folder {
        return try storage.createSubfolder(at: parent, named: name)
    }

    /// Create a new subfolder with a given name. This method throws an error
    /// if a subfolder with the given name already exists.
    /// - parameter name: The name of the subfolder to create.xrrrrr
    /// - throws: `WriteError` if the operation couldn't be completed.
    @discardableResult
    func createSubfolder(named name: String) throws -> Folder {
        return try storage.createSubfolder(at: name)
    }

    /// Create a new subfolder at a given path within this folder. In case
    /// the intermediate folders between this folder and the new one don't
    /// exist, those will be created as well. If a folder already exists at
    /// the given path, then it will be returned without modification.
    /// - parameter path: The relative path of the subfolder.
    /// - throws: `WriteError` if a new folder couldn't be created.
    @discardableResult
    func createSubfolderIfNeeded(at path: String) throws -> Folder {
        return try (try? subfolder(at: path)) ?? createSubfolder(at: path)
    }

    /// Create a new subfolder with a given name. If a subfolder with the given
    /// name already exists, then it will be returned without modification.
    /// - parameter name: The name of the subfolder.
    /// - throws: `WriteError` if a new folder couldn't be created.
    @discardableResult
    func createSubfolderIfNeeded(withName name: String) throws -> Folder {
        return try (try? subfolder(named: name)) ?? createSubfolder(named: name)
    }

    /// Return a file at a given path within this folder.
    /// - parameter path: A relative path within this folder.
    /// - throws: `LocationError` if the file couldn't be found.
    func file(at path: String) throws -> File {
        return try storage.file(at: path)
    }

    /// Return a file within this folder with a given name.
    /// - parameter name: The name of the file to return.
    /// - throws: `LocationError` if the file couldn't be found.
    func file(named name: String) throws -> File {
        return try storage.file(at: name)
    }

    /// Return whether this folder contains a file at a given path.
    /// - parameter path: The relative path of the file to look for.
    func containsFile(at path: String) -> Bool {
        return (try? file(at: path)) != nil
    }

    /// Return whether this folder contains a file with a given name.
    /// - parameter name: The name of the file to look for.
    func containsFile(named name: String) -> Bool {
        return (try? file(named: name)) != nil
    }

    /// Return whether this folder contains a given location as a direct child.
    /// - parameter location: The location to find.
    func contains<T: Location>(_ location: T) -> Bool {
        switch T.kind {
        case .file: return containsFile(named: location.name)
        case .folder: return containsSubfolder(named: location.name)
        }
    }

    /// Move the contents of this folder to a new parent
    /// - parameter folder: The new parent folder to move this folder's contents to.
    /// - parameter includeHidden: Whether hidden files should be included (default: `false`).
    /// - throws: `LocationError` if the operation couldn't be completed.
    func moveContents(to folder: Folder, includeHidden: Bool = false) throws {
        var files = self.files
        files.includeHidden = includeHidden
        try files.move(to: folder)

        var folders = subfolders
        folders.includeHidden = includeHidden
        try folders.move(to: folder)
    }

}
