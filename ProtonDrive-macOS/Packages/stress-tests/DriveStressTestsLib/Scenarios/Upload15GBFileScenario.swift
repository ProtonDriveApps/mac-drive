//
//  Upload15GBFileScenario.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 18/01/2024.
//

import Foundation

@MainActor
class Upload15GBFileScenario: Scenario {

    private let fileSize = 15.GB

    func run(domainURL: URL) async throws {
        let folderName = "15GBFolder"

        try FolderCreator.createFolder(at: domainURL, named: folderName)
        let url = domainURL.appending(component: folderName)

        let createLargeFiletask = try await FileCreator.createLargeFileTask(at: url, named: "15GBFile", targetSize: fileSize)
        let performFileCreation = createLargeFiletask.withPerformanceLogging(taskName: "Upload15GBFileScenario")
        try await performFileCreation()
    }
}
