//
//  Mover.swift
//  DriveStressTests
//
//  Created by Rob on 15.01.2024.
//

import Foundation

class Mover {
    static func rename(_ url: URL, to name: String) throws {
        let fileManager = FileManager.default
        let newURL = url.deletingLastPathComponent().appending(path: name)
        do {
            try fileManager.moveItem(at: url, to: newURL)
        } catch {
            print("Failed to rename \"\(url.lastPathComponent)\" in \(url.deletingLastPathComponent()) to \"\(name)\"")
            throw error
        }
    }
    
    static func move(itemAt previousURL: URL, to parentURL: URL) throws {
        let fileManager = FileManager.default
        let newURL = parentURL.appending(path: previousURL.lastPathComponent)
        do {
            try fileManager.moveItem(at: previousURL, to: newURL)
        } catch {
            print("Failed to move item at \(previousURL) to \(newURL)")
            throw error
        }
    }
}
