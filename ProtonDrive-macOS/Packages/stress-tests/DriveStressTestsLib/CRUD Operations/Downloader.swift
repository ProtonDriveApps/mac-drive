//
//  Downloader.swift
//  DriveStressTests
//
//  Created by Rob on 15.01.2024.
//

import Foundation

class Downloader {
    static func fetchChildNames(of url: URL) throws {
        let fileManager = FileManager.default
        do {
            let children = try fileManager.contentsOfDirectory(atPath: url.path())
            print("Children: \(children)")
        } catch {
            print("Failed to fetch children of \(url)")
            throw error
        }
    }
    
    static func download(_ url: URL) throws {
        if url.isDirectory {
            try Self.downloadContents(of: url)
        } else {
            try Self.downloadFile(url)
        }
    }
    
    static private func downloadFile(_ url: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.startDownloadingUbiquitousItem(at: url)
        } catch {
            print("Failed to download file \(url)")
            throw error
        }
    }
    
    static private func downloadContents(of url: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: url.path()) else {
            print("Failed to create directory enumerator for \(url)")
            throw NSError.init(domain: "Directory enumerator could not be created", code: -1)
        }
        
        while let subpath = enumerator.nextObject() as? String {
            do {
                try fileManager.startDownloadingUbiquitousItem(at: url.appending(path: subpath))
            } catch {
                print("Failed to download content of \(subpath)")
                throw error
            }
        }
    }
    
    static func removeDownload(of url: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.evictUbiquitousItem(at: url)
        } catch {
            print("Failed to remove the download \(url)")
            throw error
        }
    }
}
