//
//  Trasher.swift
//  DriveStressTests
//
//  Created by Rob on 15.01.2024.
//

import Foundation

class Trasher {
    static func trash(at url: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        } catch {
            print("Failed to trash \(url)")
            throw error
        }
    }
}
