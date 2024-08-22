//
//  UploadFoldersWithDeeperLevelSubfoldersScenario.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 25/01/2024.
//

import Foundation

/// - Upload folder with 500 files + 5 sub folder each with 500 files and 3 sub folder each of which have 500 more files > 2 mb
@MainActor
final class UploadFoldersWithDeeperLevelSubfoldersScenario: Scenario {

    private let fileSize = 1.MB
    private let minSubFolderFileSize = 2.MB
    private let maxSubFolderFileSize = 10.MB
    private let numberOfFolderFiles = 500
    private let numberOfSubFolderFiles = 500

    func run(domainURL: URL) async throws {
        let folderName = "500FilesAnd5Subfolders"
        let subfolderLevel1Prefix = "500FilesAnd3Subfolders"
        let subfolderLevel2Prefix = "500FilesOfMin2MBEach"

        try FolderCreator.createFolder(at: domainURL, named: folderName)
        let mainFolderURL = domainURL.appending(component: folderName)
        try await withThrowingTaskGroup(of: Void.self) { group in
            let createFilesTask = try await FileCreator.createFilesTask(in: mainFolderURL, count: numberOfFolderFiles, fileSize: fileSize)
            let performFileCreation = createFilesTask.withPerformanceLogging(taskName: "Upload500FilesScenario")
            try await performFileCreation()

            for subfolderIndex in 1...5 {
                let subfolder = try FolderCreator.createSubfolder(
                    at: mainFolderURL,
                    named: "\(subfolderLevel1Prefix)-\(subfolderIndex)"
                )
                let createFilesTask = try await FileCreator.createFilesTask(in: subfolder.url, count: numberOfSubFolderFiles, minFileSize: minSubFolderFileSize, maxFileSize: maxSubFolderFileSize)
                let performFileCreation = createFilesTask.withPerformanceLogging(taskName: "Upload500FilesInLevelSubfolders-\(subfolderIndex) Scenario")
                try await performFileCreation()

                for subfolderIndexL2 in 1...3 {
                    let subfolderLevel2 = try FolderCreator.createSubfolder(
                        at: subfolder.url,
                        named: "\(subfolderLevel2Prefix)-\(subfolderIndexL2)"
                    )
                    let createFilesTask = try await FileCreator.createFilesTask(in: subfolderLevel2.url, count: numberOfSubFolderFiles, minFileSize: minSubFolderFileSize, maxFileSize: maxSubFolderFileSize)
                    let performFileCreation = createFilesTask.withPerformanceLogging(taskName: "Upload500FilesIn3Subfolders-\(subfolderIndexL2) Scenario")
                    try await performFileCreation()
                }
            }
            try await group.waitForAll()
        }
    }
}
