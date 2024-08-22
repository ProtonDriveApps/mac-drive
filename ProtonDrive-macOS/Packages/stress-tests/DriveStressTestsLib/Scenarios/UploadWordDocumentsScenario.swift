//
//  UploadWordDocumentsScenario.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 25/01/2024.
//

import Foundation

/// - Upload folder with 25 word documents > 100kb
@MainActor
final class UploadWordDocumentsScenario: Scenario {

    private let fileSize = 100.kB
    private let numberOfFiles = 25

    func run(domainURL: URL) async throws {
        let folderName = "25WordDocuments"
        try FolderCreator.createFolder(at: domainURL, named: folderName)
        let url = domainURL.appending(component: folderName)
        let randomSize = Int.random(in: 100..<1024, using: &Constants.seededRNG).kB
        let createWordDocumentsTask = FileCreationTask {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 1...25 {
                    group.addTask {
                        try await FileCreator.createWordDocument(at: url, named: "Document\(index)", fileSize: randomSize)
                    }
                }
                try await group.waitForAll()
            }
        }
        let performFileCreation = createWordDocumentsTask.withPerformanceLogging(taskName: "UploadWordDocumentsScenario")
        try await performFileCreation()
    }
}
