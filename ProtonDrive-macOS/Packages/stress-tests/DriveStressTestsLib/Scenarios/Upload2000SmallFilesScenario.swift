//
//  Upload200FilesScenario.swift
//  DriveStressTests
//
//  Created by Rob on 18.01.2024.
//

import Foundation

@MainActor
class Upload2000SmallFilesScenario: Scenario {
    
    enum VerificationError: LocalizedError {
        case itemNotUploaded(URL)
    }

    private let fileSize: Int
    private let numberOfFiles: Int
    
    init(fileSize: Int = 1.MB, numberOfFiles: Int = 2000) {
        self.fileSize = fileSize
        self.numberOfFiles = numberOfFiles
    }

    func run(domainURL: URL) async throws -> [URL] {
        // Generate 2000 files with names formated "fileX.txt"
        // where X is a number starting at 1, ending at 2000
        // file1.txt
        // file2.txt
        // ...
        let folderName = "2000Files"
        try FolderCreator.createFolder(at: domainURL, named: folderName)
        let url = domainURL.appending(component: folderName)
        let createFilesTask = try await FileCreator.createFilesTask(in: url, count: numberOfFiles, fileSize: fileSize)
        let performFileCreation = createFilesTask.withPerformanceLogging(taskName: "Upload2000SmallFilesScenario")
        return try await performFileCreation()
    }
    
    func verify(result: [URL]) -> () throws -> Void {
        return {
            for url in result {
                let item = try FileProviderClient.fileProviderItem(for: url.path())
                guard item.isUploaded else {
                    throw VerificationError.itemNotUploaded(url)
                }
            }
        }
    }
}
