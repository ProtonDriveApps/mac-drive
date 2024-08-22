//
//  UploadMultiple5GBFilesScenario.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 19/01/2024.
//

import Foundation

@MainActor
class UploadMultiple5GBFilesScenario: Scenario {

    private let fileSize = 5.GB
    private let numberOfFiles = 10

    func run(domainURL: URL) async throws {
        let folderName = "Multiple5GBFolder"

        try FolderCreator.createFolder(at: domainURL, named: folderName)
        let url = domainURL.appending(component: folderName)

        let createMultipleFilesTask = try await FileCreator.createMultipleFilesTask(at: url, count: numberOfFiles, fileSize: fileSize)
          let performFileCreation = createMultipleFilesTask.withPerformanceLogging(taskName: "UploadMultiple5GBFilesScenario")

          try await performFileCreation()
    }
}
