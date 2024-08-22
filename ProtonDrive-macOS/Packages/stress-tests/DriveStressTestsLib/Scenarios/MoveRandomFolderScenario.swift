//
//  MoveRandomFolderScenario.swift
//  DriveStressTests
//
//  Created by Rob on 18.01.2024.
//

import Foundation

@MainActor
class MoveRandomFolderScenario: Scenario {
    
    func run(domainURL: URL) async throws {
        // get all folders and choose one at random to move to another random one (+ root)
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(at: domainURL,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            print("Failed to create directory enumerator for \(domainURL)")
            throw NSError.init(domain: "Directory enumerator could not be created", code: -1)
        }

        let allFolders = enumerator.allObjects.map { $0 as! URL }.filter { $0.isDirectory }
        
        // eligable folders for moving
        var movableFolders = allFolders
        
        // must have at least two folders AND
        // can only select top level folder if there is at least one other folder in root
        guard movableFolders.count >= 2 else {
            print("No folders in a movable state, skipping scenario")
            return
        }
        
        let immediateFolders = try fileManager
            .contentsOfDirectory(at: domainURL,
                                 includingPropertiesForKeys: [.isDirectoryKey],
                                 options: [.skipsHiddenFiles, .skipsPackageDescendants])
            .filter { $0.isDirectory }
        if immediateFolders.count == 1 {
            // can't move the single top-level folder, must pick one below
            movableFolders.removeFirst()
        }
        
        // randomly select a folder to move
        let folderToMove = movableFolders.randomElement(using: &Constants.seededRNG)!
        
        // randomly select a destination folder
        let possibleDestinations = (allFolders + [domainURL]).filter { url in
            url != folderToMove && // can't be the same as folder being moved
            url != folderToMove.deletingLastPathComponent() && // can't be direct parent
            !url.path().contains(folderToMove.path()) // can't be a child of the folder being moved
        }

        let destinationFolder = possibleDestinations.randomElement(using: &Constants.seededRNG)!
        
        try Mover.move(itemAt: folderToMove, to: destinationFolder)
    }
}
