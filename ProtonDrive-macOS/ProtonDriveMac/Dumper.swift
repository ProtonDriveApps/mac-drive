// Copyright (c) 2024 Proton AG
//
// This file is part of Proton Drive.
//
// Proton Drive is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Proton Drive is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Proton Drive. If not, see https://www.gnu.org/licenses/.

import Foundation
import AppKit
import PDCore
import FileProvider

struct DumperDependencies {
    let tower: Tower
    let domainOperationsService: DomainOperationsService
}

struct Dumper {
    private let dependencies: DumperDependencies
    
    init(dependencies: DumperDependencies) {
        self.dependencies = dependencies
    }
    
    private let sorter: NodeProviderNameSorter = {
        $0 < $1
    }
    
    private let obfuscator: NodeProviderNameObfuscator = { name in
        #if HAS_QA_FEATURES
        if UserDefaults.standard.bool(forKey: QASettingsConstants.shouldObfuscateDumpsStorage) {
            name = Emojifier.emoji.symbolicate(name)
        }
        #else
        name = Emojifier.emoji.symbolicate(name)
        #endif
    }
    
    private func logsDirectory() throws -> URL {
        try PDFileManager.getLogsDirectory()
    }
    
    func dumpFSReplica() async throws {
        let root = try await dependencies.domainOperationsService.getUserVisibleURLForRoot()
        
        // Otherwise FileProvider would fetch contents of unvisited folders from the cloud and will change contents of DB
        try await dependencies.domainOperationsService.dumpingStarted()
        defer {
            dependencies.domainOperationsService.cleanAfterDumping()
        }
        
        // Otherwise system will not allow the process to access the directory
        guard root.startAccessingSecurityScopedResource() else {
            fatalError("Could not open domain (failed to access URL resource)")
        }
        defer {
            root.stopAccessingSecurityScopedResource()
        }
        
        let dumper = FileSystemHierarchyDumper()
        let output = try await dumper.dump(root: root, sorter: sorter, obfuscator: obfuscator)
        let url = try writeToLogsDirectory(output, filename: "FileSystem-dump-" + Date().ISO8601Format() + ".diag", under: logsDirectory())
        _ = NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
    
    func dumpDBReplica() async throws {
        // otherwise tray app would not know of recent changes in persistent store
        dependencies.tower.storage.mainContext.performAndWait {
            dependencies.tower.storage.mainContext.reset()
        }
        dependencies.tower.storage.backgroundContext.performAndWait {
            dependencies.tower.storage.backgroundContext.reset()
        }
        
        let dumper = TowerHierarchyDumper()
        let output = try await dumper.dump(tower: dependencies.tower, sorter: sorter, obfuscator: obfuscator)
        let url = try writeToLogsDirectory(output, filename: "CoreData-dump-" + Date().ISO8601Format() + ".diag", under: logsDirectory())
        _ = NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
    
    func dumpCloudReplica() async throws {
        let dumper = CloudHierarchyDumper()
        let output = try await dumper.dump(client: dependencies.tower.client, sessionVault: dependencies.tower.sessionVault, sorter: sorter, obfuscator: obfuscator)
        let url = try writeToLogsDirectory(output, filename: "Cloud-dump-" + Date().ISO8601Format() + ".diag", under: logsDirectory())
        _ = NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
    
    private func writeToLogsDirectory(_ output: String, filename: String, under directory: @autoclosure () throws -> URL) throws -> URL {
        let logsDirectory = try directory()
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true, attributes: nil)
        
        let fileURL = logsDirectory.appendingPathComponent(filename)
        try FileManager.default.secureFilesystemItems(fileURL)
        let success = FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: output.data(using: .utf8))
        assert(success, "Failed to write dump to file: \(fileURL.path(percentEncoded: false))")
        
        return fileURL
    }
}
