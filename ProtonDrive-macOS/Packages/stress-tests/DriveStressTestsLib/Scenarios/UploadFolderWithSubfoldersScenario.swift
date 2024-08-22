//
//  UploadFolderWithSubfoldersScenario.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 23/01/2024.
//

import Foundation

/// - Upload folder with 2000 files + 3 sub folders each with 1000 files each > 2mb
@MainActor
class UploadFolderWithSubfoldersScenario: Scenario {

    private let fileSize = 1.MB
    private let minSubFolderFileSize = 2.MB
    private let maxSubFolderFileSize = 10.MB
    private let numberOfFolderFiles = 2000
    private let numberOfSubFolderFiles = 1000

    func run(domainURL: URL) async throws {
        let folderName = "2000FilesAnd3Subfolders"
        let subfolderPrefix = "1000FilesOfMin2MBEach"

        try FolderCreator.createFolder(at: domainURL, named: folderName)
        let mainFolderURL = domainURL.appending(component: folderName)
        try await withThrowingTaskGroup(of: Void.self) { group in
            let createFilesTask = try await FileCreator.createFilesTask(in: mainFolderURL, count: numberOfFolderFiles, fileSize: fileSize)
            let performFileCreation = createFilesTask.withPerformanceLogging(taskName: "Upload2000FilesScenario")
            try await performFileCreation()

            for subfolderIndex in 1...3 {
                let subfolder = try FolderCreator.createSubfolder(
                    at: mainFolderURL,
                    named: "\(subfolderPrefix)-\(subfolderIndex)"
                )
                let createFilesTask = try await FileCreator.createFilesTask(in: subfolder.url, count: numberOfSubFolderFiles, minFileSize: minSubFolderFileSize, maxFileSize: maxSubFolderFileSize)
                let performFileCreation = createFilesTask.withPerformanceLogging(taskName: "Upload1000FilesInSubfolder\(subfolderIndex) Scenario")
                try await performFileCreation()
            }
            try await group.waitForAll()
        }
    }
}
