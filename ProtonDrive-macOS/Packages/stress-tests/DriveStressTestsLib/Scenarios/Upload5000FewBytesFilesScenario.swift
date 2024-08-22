//
//  Upload5000FewBytesFilesScenario.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 19/01/2024.
//

import Foundation

@MainActor
class Upload5000FewBytesFilesScenario: Scenario {

    private let minFileSize = 1.kB
    private let maxFileSize = 500.kB
    private let numberOfFiles = 5000

    func run(domainURL: URL) async throws {
        let folderName = "5000Files"
        try FolderCreator.createFolder(at: domainURL, named: folderName)
        let url = domainURL.appending(component: folderName)
        let createFilesTask = try await FileCreator.createFilesTask(in: url, count: numberOfFiles, minFileSize: minFileSize, maxFileSize: maxFileSize)
        let performFileCreation = createFilesTask.withPerformanceLogging(taskName: "Upload5000FewBytesFilesScenario")

        try await performFileCreation()
    }
}
