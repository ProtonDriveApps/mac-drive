//
//  EditSimultaneouslyMultipleFilesScenario.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 25/01/2024.
//

import Foundation
import os

/// - Edit 100 files at the same time
@MainActor
final class EditSimultaneouslyMultipleFilesScenario: Scenario {

    private let numberOfFiles = 100

    func run(domainURL: URL) async throws {

        let folderName = "FolderForFileEditing".appendingSuffixIfNeeded("/")

        try FolderCreator.createFolder(at: domainURL, named: folderName)
        let mainFolderURL = domainURL.appending(component: folderName)

        try await FileCreator.createFiles(in: mainFolderURL, count: numberOfFiles, fileSize: 1.kB)

        let fileEditingTask = FileCreationTask {
            let newContent = "Appending new line of text.\n"
            try await FileEditor.editFilesConcurrently(
                at: mainFolderURL, numberOfFiles: self.numberOfFiles, withContent: newContent)
        }

        let performFileEditing = fileEditingTask.withPerformanceLogging(taskName: "EditSimultaneouslyMultipleFilesScenario")
        try await performFileEditing()
    }
}
