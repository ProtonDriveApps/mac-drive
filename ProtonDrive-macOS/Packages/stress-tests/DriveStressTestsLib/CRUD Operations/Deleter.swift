//
//  Deleter.swift
//  DriveStressTests
//
//  Created by Rob on 15.01.2024.
//

import Foundation

class Deleter {
    static func delete(at url: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: url)
        } catch {
            print("Failed to delete \(url)")
            throw error
        }
    }
}
