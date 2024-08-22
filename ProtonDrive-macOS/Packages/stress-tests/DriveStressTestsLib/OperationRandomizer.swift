//
//  OperationRandomizer.swift
//  DriveStressTests
//
//  Created by Rob on 15.01.2024.
//

import Foundation

@MainActor
public final class OperationRandomizer {
    
    public init() {}
    
    @MainActor
    public func runTest(domainURL: URL) async throws -> () throws -> Void {
        guard FileManager.default.fileExists(atPath: domainURL.path()) else {
            throw NSError(domain: "Root directory not found", code: -1)
        }

        // Upload2000SmallFilesScenario
        let upload2000SmallFilesScenario = Upload2000SmallFilesScenario(fileSize: 1.kB, numberOfFiles: 50)
        let result = try await upload2000SmallFilesScenario.run(domainURL: domainURL)
        return upload2000SmallFilesScenario.verify(result: result)

        // Upload15GBFileScenario
        /*let upload15GBFileScenario = Upload15GBFileScenario()
        try await upload15GBFileScenario.run()*/

        // UploadMultiple5GBFilesScenario
        /*let uploadMultiple5GBFilesScenario = UploadMultiple5GBFilesScenario()
        try await uploadMultiple5GBFilesScenario.run()*/

        // Upload5000FewBytesFilesScenario
        /*let upload5000FewBytesFilesScenario = Upload5000FewBytesFilesScenario()
        try await upload5000FewBytesFilesScenario.run()*/
        
        // UploadFolderWithSubfoldersScenario
        // let uploadFolderWithSubfoldersScenario = UploadFolderWithSubfoldersScenario()
        // try await uploadFolderWithSubfoldersScenario.run()

        // UploadFoldersWithDeeperLevelSubfoldersScenario
        // let uploadFoldersWithDeeperLevelSubfoldersScenario = UploadFoldersWithDeeperLevelSubfoldersScenario()
        // try await uploadFoldersWithDeeperLevelSubfoldersScenario.run()

        // UploadWordDocumentsScenario
        // let uploadWordDocumentsScenario = UploadWordDocumentsScenario()
        // try await uploadWordDocumentsScenario.run()

        // Manipulation scenarios
        /*let moveRandomScenario = MoveRandomFolderScenario()
        try await moveRandomScenario.run()*/

        // Edit scenarios
        // let editFileMultipleTimesScenario = EditFileMultipleTimesScenario()
        // try await editFileMultipleTimesScenario.run()

        // let editSimultaneouslyMultipleFilesScenario = EditSimultaneouslyMultipleFilesScenario()
        // try await editSimultaneouslyMultipleFilesScenario.run()

        // Trashing scenarios
        // let trashLargeFolderScenario = TrashLargeFolderScenario()
        // try await trashLargeFolderScenario.run()

        // Deleting scenarios
        // let deleteLargeFolderScenario = DeleteLargeFolderScenario()
        // try await deleteLargeFolderScenario.run()
    }
}
