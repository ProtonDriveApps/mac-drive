//
//  FileProviderClient.swift
//  DriveStressTests
//
//  Created by krzysztof.siejkowski@proton.ch on 31/01/2024.
//

import Foundation
import UniformTypeIdentifiers
import FileProvider

enum FileProviderClientError: LocalizedError {
    case invalidProcessOutput
    case processErroredOut
    case keyNotFound(String)
}

enum FileProviderClient {
    
    enum Commands {
        case attributes(path: String)
        case evaluate(path: String)
        
        var arguments: [String] {
            switch self {
            case .attributes(let path):
                return ["attributes", path]
            case .evaluate(let path):
                return ["evaluate", path]
            }
        }
    }
    
    static let fileProviderToolURL: URL = {
        let fileProviderTool = URL(filePath: "/usr/bin/fileproviderctl")
        guard FileManager.default.fileExists(atPath: fileProviderTool.path())
        else {
            fatalError("Could not find the file provider tool: fileproviderctl")
        }
        return fileProviderTool
    }()
    
    static func attributes(for path: String) throws -> FileAttributes {
        try execute(command: .evaluate(path: path), parsing: FileAttributes.init)
    }
    
    static func fileProviderItem(for path: String) throws -> FileProviderItem {
        try execute(command: .evaluate(path: path), parsing: FileProviderItem.init)
    }
    
    private static func execute<T>(command: Commands, parsing: (String) throws -> T) throws -> T {
        let process = Process()
        process.executableURL = fileProviderToolURL
        let pipe = Pipe()
        process.standardOutput = pipe
        
        process.arguments = command.arguments
        
        try process.run()
        
        process.waitUntilExit()
        switch process.terminationReason {
        case .uncaughtSignal:
            throw FileProviderClientError.processErroredOut
        case .exit:
            guard let data = try pipe.fileHandleForReading.readToEnd(),
                  let output = String(data: data, encoding: .utf8)
            else { throw FileProviderClientError.invalidProcessOutput }
            return try parsing(output)
        @unknown default:
            fatalError()
        }
    }
}

struct FileProviderItem: Codable {
    let capabilities: UInt64
    let contentModificationDate: Date
    let contentType: UTType
    let creationDate: Date
    let displayName: String
    let documentSize: UInt64
    let filename: String
    let hasUnresolvedConflicts: Bool? // can be nil if file provider has not picked it up yet
    let inheritedUserInfo: String? // can be nil, should be a dict but I don't know the schema
    let isDownloadRequested: Bool? // can be nil if file provider has not picked it up yet
    let isDownloaded: Bool
    let isDownloading: Bool
    let isExcludedFromSync: Bool
    let isFolder: Bool
    let isMostRecentVersionDownloaded: Bool
    let isRecursivelyDownloaded: Bool
    let isShared: Bool
    let isSharedByCurrentUser: Bool
    let isTrashed: Bool
    let isUploaded: Bool
    let isUploading: Bool
    let itemIdentifier: String? // can be nil if file provider has not picked it up yet
    let parentItemIdentifier: String
    let typeIdentifier: UTType
    let versionIdentifier: String? // can be nil, should be data but it's truncated in the standard output
    
    enum CodingKeys: String, CodingKey, LosslessStringConvertible {
        var description: String { rawValue }
        
        init?(_ description: String) {
            self.init(rawValue: description)
        }
        
        case capabilities
        case contentModificationDate
        case contentType
        case creationDate
        case displayName
        case documentSize
        case filename
        case hasUnresolvedConflicts
        case inheritedUserInfo
        case isDownloadRequested
        case isDownloaded
        case isDownloading
        case isExcludedFromSync
        case isFolder
        case isMostRecentVersionDownloaded
        case isRecursivelyDownloaded
        case isShared
        case isSharedByCurrentUser
        case isTrashed
        case isUploaded
        case isUploading
        case itemIdentifier
        case parentItemIdentifier
        case typeIdentifier
        case versionIdentifier
    }
    
    init(from output: String) throws {
        guard let content = output.split(separator: "Actions:", maxSplits: 1).first else { throw FileProviderClientError.invalidProcessOutput }
        let keysWithValues = content
            .split(separator: "\n")
            .dropFirst(3)
            .dropLast(3)
            .map { $0.split(separator: " = ", maxSplits: 1) }
            .filter { $0.count == 2 }
            .compactMap { elements in
                elements.last.flatMap {
                    (
                        elements.first.flatMap { CodingKeys(rawValue: String($0).trimmingCharacters(in: .whitespaces)) },
                        $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\";")) // dropping last ";"
                    )
                }
            }
            .compactMap { tuple in tuple.0.flatMap { ($0, String(tuple.1)) } }
        let dictionary = Dictionary(uniqueKeysWithValues: keysWithValues)
        
        self.capabilities = try dictionary.uint64(key: .capabilities)
        self.contentModificationDate = try dictionary.date(key: .contentModificationDate)
        self.contentType = try dictionary.uttype(key: .contentType)
        self.creationDate = try dictionary.date(key: .creationDate)
        self.displayName = try dictionary.string(key: .displayName)
        self.documentSize = try dictionary.uint64(key: .documentSize)
        self.filename = try dictionary.string(key: .filename)
        self.hasUnresolvedConflicts = try? dictionary.bool(key: .hasUnresolvedConflicts)
        self.inheritedUserInfo = try? dictionary.string(key: .inheritedUserInfo)
        self.isDownloadRequested = try? dictionary.bool(key: .isDownloadRequested)
        self.isDownloaded = try dictionary.bool(key: .isDownloaded)
        self.isDownloading = try dictionary.bool(key: .isDownloading)
        self.isExcludedFromSync = try dictionary.bool(key: .isExcludedFromSync)
        self.isFolder = try dictionary.bool(key: .isFolder)
        self.isMostRecentVersionDownloaded = try dictionary.bool(key: .isMostRecentVersionDownloaded)
        self.isRecursivelyDownloaded = try dictionary.bool(key: .isRecursivelyDownloaded)
        self.isShared = try dictionary.bool(key: .isShared)
        self.isSharedByCurrentUser = try dictionary.bool(key: .isSharedByCurrentUser)
        self.isTrashed = try dictionary.bool(key: .isTrashed)
        self.isUploaded = try dictionary.bool(key: .isUploaded)
        self.isUploading = try dictionary.bool(key: .isUploading)
        self.itemIdentifier = try? dictionary.string(key: .itemIdentifier)
        self.parentItemIdentifier = try dictionary.string(key: .parentItemIdentifier)
        self.typeIdentifier = try dictionary.uttype(key: .typeIdentifier)
        self.versionIdentifier = try? dictionary.string(key: .versionIdentifier)
    }
}

struct FileAttributes: Codable {
    let contentAccessDate: Date
    let contentModificationDate: Date
    let creationDate: Date
    let fileSize: UInt64? // nil for folders
    let isReadable: Bool
    let isUbiquitousItem: Bool? // nil if file outside file provider domain
    let isWritable: Bool
    let localizedName: String
    let name: String
    let typeIdentifier: UTType
    let ubiquitousItemDownloadingError: String?
    let ubiquitousItemDownloadingStatus: URLUbiquitousItemDownloadingStatus?
    let ubiquitousItemHasUnresolvedConflicts: Bool?
    let ubiquitousItemIsDownloading: Bool?
    let ubiquitousItemIsExcludedFromSync: Bool?
    let ubiquitousItemIsShared: Bool?
    let ubiquitousItemIsUploaded: Bool?
    let ubiquitousItemIsUploading: Bool?
    let ubiquitousItemUploadingError: String?
    let ubiquitousSharedItemCurrentUserPermissions: String?
    let ubiquitousSharedItemCurrentUserRole: String?
    let ubiquitousSharedItemMostRecentEditorNameComponents: String?
    let ubiquitousSharedItemOwnerNameComponents: String?
    let ubiquitousSharedItemPermissions: String?
    
    enum CodingKeys: String, CodingKey, LosslessStringConvertible {
        var description: String { rawValue }
        
        init?(_ description: String) { self.init(rawValue: description) }
        
        case contentAccessDate = "NSURLContentAccessDateKey"
        case contentModificationDate = "NSURLContentModificationDateKey"
        case creationDate = "NSURLCreationDateKey"
        case fileSize = "NSURLFileSizeKey"
        case isReadable = "NSURLIsReadableKey"
        case isUbiquitousItem = "NSURLIsUbiquitousItemKey"
        case isWritable = "NSURLIsWritableKey"
        case localizedName = "NSURLLocalizedNameKey"
        case name = "NSURLNameKey"
        case typeIdentifier = "NSURLTypeIdentifierKey"
        case ubiquitousItemDownloadingError = "NSURLUbiquitousItemDownloadingErrorKey"
        case ubiquitousItemDownloadingStatus = "NSURLUbiquitousItemDownloadingStatusKey"
        case ubiquitousItemHasUnresolvedConflicts = "NSURLUbiquitousItemHasUnresolvedConflictsKey"
        case ubiquitousItemIsDownloading = "NSURLUbiquitousItemIsDownloadingKey"
        case ubiquitousItemIsExcludedFromSync = "NSURLUbiquitousItemIsExcludedFromSyncKey"
        case ubiquitousItemIsShared = "NSURLUbiquitousItemIsSharedKey"
        case ubiquitousItemIsUploaded = "NSURLUbiquitousItemIsUploadedKey"
        case ubiquitousItemIsUploading = "NSURLUbiquitousItemIsUploadingKey"
        case ubiquitousItemUploadingError = "NSURLUbiquitousItemUploadingErrorKey"
        case ubiquitousSharedItemCurrentUserPermissions = "NSURLUbiquitousSharedItemCurrentUserPermissionsKey"
        case ubiquitousSharedItemCurrentUserRole = "NSURLUbiquitousSharedItemCurrentUserRoleKey"
        case ubiquitousSharedItemMostRecentEditorNameComponents = "NSURLUbiquitousSharedItemMostRecentEditorNameComponentsKey"
        case ubiquitousSharedItemOwnerNameComponents = "NSURLUbiquitousSharedItemOwnerNameComponentsKey"
        case ubiquitousSharedItemPermissions = "NSURLUbiquitousSharedItemPermissionsKey"
    }
    
    init(from output: String) throws {
        let keysWithValues = output.split(separator: "\n")
            .map { $0.split(separator: ":", maxSplits: 1) }
            .filter { $0.count == 2 }
            .compactMap { elements in
                elements.last.flatMap {
                    (
                        elements.first.flatMap { CodingKeys(rawValue: String($0)) },
                        $0.trimmingCharacters(in: .whitespaces)
                    )
                }
            }
            .compactMap { tuple in tuple.0.flatMap { ($0, String(tuple.1)) } }
        let dictionary = Dictionary(uniqueKeysWithValues: keysWithValues)
        
        self.contentAccessDate = try dictionary.date(key: .contentAccessDate)
        self.contentModificationDate = try dictionary.date(key: .contentModificationDate)
        self.creationDate = try dictionary.date(key: .creationDate)
        self.fileSize = try dictionary.uint64(key: .fileSize)
        self.isReadable = try dictionary.bool(key: .isReadable)
        self.isUbiquitousItem = try dictionary.bool(key: .isUbiquitousItem)
        self.isWritable = try dictionary.bool(key: .isWritable)
        self.localizedName = try dictionary.string(key: .localizedName)
        self.name = try dictionary.string(key: .name)
        self.typeIdentifier = try dictionary.uttype(key: .typeIdentifier)
        self.ubiquitousItemDownloadingError = try dictionary.string(key: .ubiquitousItemDownloadingError)
        self.ubiquitousItemDownloadingStatus = try dictionary.itemDownloadingStatus(key: .ubiquitousItemDownloadingStatus)
        self.ubiquitousItemHasUnresolvedConflicts = try dictionary.bool(key: .ubiquitousItemHasUnresolvedConflicts)
        self.ubiquitousItemIsDownloading = try dictionary.bool(key: .ubiquitousItemIsDownloading)
        self.ubiquitousItemIsExcludedFromSync = try dictionary.bool(key: .ubiquitousItemIsExcludedFromSync)
        self.ubiquitousItemIsShared = try dictionary.bool(key: .ubiquitousItemIsShared)
        self.ubiquitousItemIsUploaded = try dictionary.bool(key: .ubiquitousItemIsUploaded)
        self.ubiquitousItemIsUploading = try dictionary.bool(key: .ubiquitousItemIsUploading)
        self.ubiquitousItemUploadingError = try dictionary.string(key: .ubiquitousItemUploadingError)
        self.ubiquitousSharedItemCurrentUserPermissions = try dictionary.string(key: .ubiquitousSharedItemCurrentUserPermissions)
        self.ubiquitousSharedItemCurrentUserRole = try dictionary.string(key: .ubiquitousSharedItemCurrentUserRole)
        self.ubiquitousSharedItemMostRecentEditorNameComponents = try dictionary.string(key: .ubiquitousSharedItemMostRecentEditorNameComponents)
        self.ubiquitousSharedItemOwnerNameComponents = try dictionary.string(key: .ubiquitousSharedItemOwnerNameComponents)
        self.ubiquitousSharedItemPermissions = try dictionary.string(key: .ubiquitousSharedItemPermissions)
    }
}

extension URLUbiquitousItemDownloadingStatus: Codable {}

extension Dictionary where Key: LosslessStringConvertible, Value == String {
    
    func date(key: Key) throws -> Date {
        guard let value = try date(key: key) else { throw FileProviderClientError.keyNotFound(key.description) }
        return value
    }
    
    func date(key: Key) throws -> Date? {
        guard let value = try self[key].map({ try Date($0, strategy: .dateTime) })
        else { throw FileProviderClientError.keyNotFound(key.description) }
        return value
    }
    
    func uint64(key: Key) throws -> UInt64 {
        guard let value = try uint64(key: key) else { throw FileProviderClientError.keyNotFound(key.description) }
        return value
    }
    
    func uint64(key: Key) throws -> UInt64? {
        guard let string = self[key] else { throw FileProviderClientError.keyNotFound(key.description) }
        guard string != "nil" else { return nil }
        return try UInt64(string, format: .number)
    }
    
    func bool(key: Key) throws -> Bool {
        guard let value = try bool(key: key) else { throw FileProviderClientError.keyNotFound(key.description) }
        return value
    }
    
    func bool(key: Key) throws -> Bool? {
        guard let string = self[key] else { throw FileProviderClientError.keyNotFound(key.description) }
        guard string != "nil" else { return nil }
        switch try Int(string, format: .number) {
        case 0: return false
        case 1: return true
        default: throw FileProviderClientError.keyNotFound(key.description)
        }
    }
    
    func string(key: Key) throws -> String {
        guard let string = try string(key: key) else { throw FileProviderClientError.keyNotFound(key.description) }
        return string
    }
    
    func string(key: Key) throws -> String? {
        guard let string = self[key] else { throw FileProviderClientError.keyNotFound(key.description) }
        guard string != "nil" else { return nil }
        return string
    }
    
    func uttype(key: Key) throws -> UTType {
        guard let string = self[key], let value = UTType(string)
        else { throw FileProviderClientError.keyNotFound(key.description) }
        return value
    }
    
    func itemDownloadingStatus(key: Key) throws -> URLUbiquitousItemDownloadingStatus {
        guard let string = self[key] else { throw FileProviderClientError.keyNotFound(key.description) }
        return URLUbiquitousItemDownloadingStatus(rawValue: string)
    }
}
