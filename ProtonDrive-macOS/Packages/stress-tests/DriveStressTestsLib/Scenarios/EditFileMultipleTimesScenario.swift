//
//  EditFileMultipleTimesScenario.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 25/01/2024.
//

import Foundation

/// - Edit a single file 100 times
@MainActor
final class EditFileMultipleTimesScenario: Scenario {

    func run(domainURL: URL) async throws {
        
        let filename = "fileToEdit.txt"
        let fileURL = domainURL.appending(component: filename)

        try FileCreator.createTextFile(at: domainURL, named: filename, with: "Initial Text.\n")

        let fileEditingTask = FileCreationTask {
            try await FileEditor.editFileMultipleTimes(
                at: fileURL, numberOfTimes: 100, delayInSeconds: Constants.randomDelay(in: 0.1...0.15))
        }

        let performFileEditing = fileEditingTask.withPerformanceLogging(taskName: "EditFileMultipleTimesScenario")
        try await performFileEditing()
    }
}
