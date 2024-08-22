//
//  Scenario.swift
//  DriveStressTests
//
//  Created by Rob on 18.01.2024.
//

import Foundation

protocol Scenario {
    associatedtype Result
    func run(domainURL: URL) async throws -> Result
//    func verify(result: Result) async throws
}

/* Scenarios:
 - Upload folder with 5000 files of a few bytes ✅
 - Upload folder with 2000 files each > 2 mb ✅
 - Upload folder with 10 files each > 5 gb ✅
 - Upload folder with 500 files + 5 sub folder each with 500 files and 3 sub folder each of which have 500 more files > 2 mb ✅
 - Upload folder with 2000 files + 3 sub folders each with 1000 files each > 2mb ✅
 - Upload folder with 25 word documents > 100kb ✅
 - Upload 1 15 gb file ✅
 - Move folder with lots of children to another folder
 - Rename many files
 - Trash large folder ✅
 - Delete large folder ✅
 - Remove download (evict) of folder contents
 - Download folder and contents
 - Edit a single file 100 times ✅
 - Edit 100 files at the same time
 - Edit 10 files 10 times each
*/
