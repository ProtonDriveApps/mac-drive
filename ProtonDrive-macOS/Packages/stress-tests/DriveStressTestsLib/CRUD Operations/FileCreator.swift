//
//  FileCreator.swift
//  DriveStressTests
//
//  Created by Rob on 15.01.2024.
//

import Foundation

@MainActor
class FileCreator {
    static func createEmptyFile(at parent: URL, named name: String) throws -> URL {
        try createFile(at: parent, named: name, with: nil)
    }
    
    static func createTextFile(at parent: URL, named name: String, with content: String) throws -> URL {
        guard let data = content.appending("\n").data(using: .utf8) else {
            print("Failed to create text file \"\(name)\" in \(parent.path()) due to encoding issue")
            throw NSError.init(domain: "File creation error", code: -1)
        }
        
        return try createFile(at: parent, named: name, with: data)
    }
    
    static private func createFile(at parent: URL, named name: String, with contents: Data?) throws -> URL {
        let fileURL = parent.appendingPathComponent(name)
        try contents?.write(to: fileURL)
        return fileURL
    }

    static func createFile(at parent: URL, number: Int, fileSize: Int) async throws -> URL {
        let fileName = "file\(number).txt"
        return try FileCreator.createRandomDataFile(at: parent, named: fileName, sizeInBytes: fileSize)
    }

    static func createFilesTask(in parent: URL, count: Int, fileSize: Int) async throws -> FileCreationTask<[URL]> {
        return FileCreationTask {
            try await createFiles(in: parent, count: count, fileSize: fileSize)
        }
    }

    static func createFilesTask(in parent: URL, count: Int, minFileSize: Int, maxFileSize: Int) async throws -> FileCreationTask<[URL]> {
        return FileCreationTask {
            try await createFiles(in: parent, count: count, minFileSize: minFileSize, maxFileSize: maxFileSize)
        }
    }

    static func createFiles(in parent: URL, count: Int, fileSize: Int) async throws -> [URL] {
        try await withThrowingTaskGroup(of: URL.self) { group in
            for i in 1...count {
                group.addTask {
                    try await createFile(at: parent, number: i, fileSize: fileSize)
                }
            }
            var urls: [URL] = []
            for try await result in group {
                urls.append(result)
            }
            return urls
        }
    }

    static func createFiles(in parent: URL, count: Int, minFileSize: Int, maxFileSize: Int) async throws -> [URL] {
        try await withThrowingTaskGroup(of: URL.self) { group in
            for i in 1...count {
                let randomFileSize = Int.random(in: minFileSize...maxFileSize, using: &Constants.seededRNG)
                group.addTask {
                    try await createFile(at: parent, number: i, fileSize: randomFileSize)
                }
            }
            var urls: [URL] = []
            for try await result in group {
                urls.append(result)
            }
            return urls
        }
    }

    static func createMultipleFilesTask(at url: URL, count: Int, fileSize: Int, withExtension ext: String = "txt") async throws -> FileCreationTask<Void> {
        return FileCreationTask(createTask: {
            try await createMultipleFiles(at: url, count: count, fileSize: fileSize, withExtension: ext)
        })
    }

    /// Fits better with medium or large file sizes
    /// In case of small files , use `createFile(at: URL, named: String, targetSize: Int)`
    static func createMultipleFiles(at parent: URL, count: Int, fileSize: Int, withExtension ext: String = "txt") async throws {
        await withThrowingTaskGroup(of: Void.self) { group in
            for i in 1...count {
                group.addTask {
                    let fileName = "file\(i).\(ext)"
                    try await createLargeFile(at: parent, named: fileName, targetSize: fileSize)
                }
            }
        }
    }

    /// Fits better with small files
    /// In case of large file (Gigabytes), use `createLargeFile(at: URL, named: String, targetSize: Int)`
    static func createRandomDataFile(at parent: URL, named name: String, sizeInBytes size: Int) throws -> URL {
        let data = emptyData(sizeInBytes: size)
        return try createFile(at: parent, named: name, with: data)
    }

    // MARK: Large files

    static func createLargeFileTask(at parent: URL, named name: String, targetSize: Int) async throws -> FileCreationTask<Void> {
        return FileCreationTask {
            try await createLargeFile(at: parent, named: name, targetSize: targetSize)
        }
    }

    static func createLargeFile(at parent: URL, named name: String, targetSize: Int) async throws {
        let fileURL = parent.appendingPathComponent(name)
        let dataString = String(repeating: "0", count: 1024 * 1024 * 100) // 100 MB of data
        let data = Data(dataString.utf8)

        try "".write(to: fileURL, atomically: true, encoding: .utf8)
        let fileHandle = try FileHandle(forWritingTo: fileURL)

        defer { try? fileHandle.close() }

        let chunkSize = data.count
        let numberOfChunks = targetSize / chunkSize

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<numberOfChunks {
                group.addTask {
                    try fileHandle.write(contentsOf: data)
                }
            }
            try await group.waitForAll()
        }
    }

    static func createWordDocument(at parent: URL, named name: String, fileSize: Int) async throws {
        let documentURL = parent.appendingPathComponent("\(name).docx")
        let sampleText = "Sample Text in Word Document"
        let dataSize = sampleText.lengthOfBytes(using: .utf8)
        let count = (fileSize + dataSize - 1) / dataSize
        let content = String(repeating: sampleText, count: count)
        try content.write(to: documentURL, atomically: true, encoding: .utf8)
    }

    // Private methods

    static private func emptyData(sizeInBytes size: Int) -> Data {
        Data(count: size)
    }
}
