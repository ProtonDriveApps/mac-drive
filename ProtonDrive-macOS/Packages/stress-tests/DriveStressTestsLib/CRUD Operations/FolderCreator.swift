//
//  FolderCreator.swift
//  DriveStressTests
//
//  Created by Rob on 15.01.2024.
//

import Foundation

class FolderCreator {
    static func createFolder(at parent: URL, named name: String) throws {
        let fileManager = FileManager.default
        let url = parent.appending(path: name, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(atPath: url.path(), withIntermediateDirectories: false)
        } catch {
            print("Failed to create folder \"\(name)\" in \(parent.path)")
            throw error
        }
    }

    // MARK: Subfolders
    
    static func createSubfolder(at parent: URL, named name: String) throws -> Folder {
        let storage = try Storage<Folder>(path: parent.path(), fileManager: .default)
        let folder = Folder(storage: storage)
        return try folder.createSubfolder(at: parent, named: name)
    }

}
