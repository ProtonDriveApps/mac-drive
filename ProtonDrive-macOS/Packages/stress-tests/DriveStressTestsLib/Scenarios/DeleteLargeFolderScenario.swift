//
//  DeleteLargeFolderScenario.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 25/01/2024.
//

import Foundation
import os

@MainActor
final class DeleteLargeFolderScenario: Scenario {

    private let minFileSize = 1.kB
    private let maxFileSize = 500.kB
    private let numberOfFiles = 5000

    func run(domainURL: URL) async throws {
        let folderName = "5000Files"
        try FolderCreator.createFolder(at: domainURL, named: folderName)
        let parent = domainURL.appending(component: folderName)

        let delay = Constants.randomDelay(in: 1...5)
        Logger.performance.info("Random delay: \(delay) seconds")

        let largeFolderDeletionTask = FileCreationTask {
            try await FileCreator.createFiles(in: parent, count: self.numberOfFiles, minFileSize: self.minFileSize, maxFileSize: self.maxFileSize)

            try await Task.sleep(seconds: delay)
            try Deleter.delete(at: parent)
        }
        let performLargeFolderDeletion = largeFolderDeletionTask.withPerformanceLogging(taskName: "DeleteLargeFolderScenario")
        try await performLargeFolderDeletion()
    }
}
