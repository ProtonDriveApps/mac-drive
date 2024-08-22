//
//  Storage+Subfolders.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 23/01/2024.
//

import Foundation

extension Storage where LocationType == Folder {
    func makeChildSequence<T: Location>() -> Folder.ChildSequence<T> {
        return Folder.ChildSequence(
            folder: Folder(storage: self),
            fileManager: fileManager,
            isRecursive: false,
            includeHidden: false
        )
    }

    func subfolder(at folderPath: String) throws -> Folder {
        let folderPath = path + folderPath.removingPrefix("/")
        let storage = try Storage(path: folderPath, fileManager: fileManager)
        return Folder(storage: storage)
    }

    func file(at filePath: String) throws -> File {
        let filePath = path + filePath.removingPrefix("/")
        let storage = try Storage<File>(path: filePath, fileManager: fileManager)
        return File(storage: storage)
    }

    func createSubfolder(at folderPath: String) throws -> Folder {
        let folderPath = path + folderPath.removingPrefix("/")

        guard folderPath != path else {
            throw WriteError(path: folderPath, reason: .emptyPath)
        }

        do {
            try fileManager.createDirectory(
                atPath: folderPath,
                withIntermediateDirectories: true
            )

            let storage = try Storage(path: folderPath, fileManager: fileManager)
            return Folder(storage: storage)
        } catch {
            throw WriteError(path: folderPath, reason: .folderCreationFailed(error))
        }
    }

    func createSubfolder(at parent: URL, named name: String) throws -> Folder {
        let subFolderPath = parent.appending(component: name, directoryHint: .isDirectory).path()

        do {
            try fileManager.createDirectory(
                atPath: subFolderPath,
                withIntermediateDirectories: true
            )

            let storage = try Storage(path: subFolderPath, fileManager: fileManager)
            return Folder(storage: storage)
        } catch {
            throw WriteError(path: subFolderPath, reason: .folderCreationFailed(error))
        }
    }
}
