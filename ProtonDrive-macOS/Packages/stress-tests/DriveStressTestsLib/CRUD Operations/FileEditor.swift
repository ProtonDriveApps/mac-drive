//
//  FileEditor.swift
//  DriveStressTests
//
//  Created by Rob on 15.01.2024.
//

import Foundation

class FileEditor {
    static private let contentLogLength = 50

    static func editFileMultipleTimes(at parent: URL, numberOfTimes: Int, delayInSeconds: Double) async throws {
        for _ in 1...numberOfTimes {
            try await Task.sleep(seconds: delayInSeconds)

            let newText = "Appending new line of text.\n"
            try append(content: newText, at: parent)
        }
    }

    static func editFilesConcurrently(at parent: URL, numberOfFiles: Int, withContent content: String) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in

            let storage = try Storage<Folder>(path: parent.path(), fileManager: .default)
            let folder = Folder(storage: storage)
            for file in folder.files {
                group.addTask {
                    try append(content: content, at: file.url)
                }
            }
            try await group.waitForAll()
        }
    }

    static func append(content: String, at url: URL) throws {
        do {
            let fileHandle = try FileHandle(forUpdating: url)
            defer { try? fileHandle.close() }
            try fileHandle.seekToEnd()
            guard let data = content.appending("\n").data(using: .utf8) else {
                print("Failed to append text file \(url) due to encoding issue")
                throw NSError.init(domain: "File editing error", code: -1)
            }
            try fileHandle.write(contentsOf: data)
        } catch {
            let contentForError: String
            if content.count > contentLogLength {
                let prefixEnd = content.index(content.startIndex, offsetBy: contentLogLength/2)
                let suffixStart = content.index(content.endIndex, offsetBy: -(contentLogLength/2))
                contentForError = String("\(content[content.startIndex..<prefixEnd])...\(content[suffixStart..<content.endIndex])")
            } else {
                contentForError = content
            }
            print("Failed to append content: \"\(contentForError)\" to file: \(url)")
            throw NSError(domain: "Failed to edit file", code: -1)
        }
    }

    static func replaceContent(at url: URL, with newText: String) throws {
        guard let data = newText.data(using: .utf8) else {
            throw NSError(domain: "Failed to generate new data", code: -1, userInfo: nil)
        }

        try data.write(to: url, options: .atomic)
    }
}
