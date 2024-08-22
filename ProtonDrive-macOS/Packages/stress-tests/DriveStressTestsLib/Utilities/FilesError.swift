//
//  FilesError.swift
//  DriveStressTests
//
//  Created by Audrey SOBGOU ZEBAZE on 22/01/2024.
//

import Foundation

public struct FilesError<Reason: Sendable>: Error {
    public var path: String
    public var reason: Reason

    public init(path: String, reason: Reason) {
        self.path = path
        self.reason = reason
    }
}

extension FilesError: CustomStringConvertible {
    public var description: String {
        return """
        Files encountered an error at '\(path)'.
        Reason: \(reason)
        """
    }
}

/// Enum listing reasons that a location manipulation could fail.
public enum LocationErrorReason : Sendable{
    /// The location couldn't be found.
    case missing
    /// An empty path was given when refering to a file.
    case emptyFilePath
    /// The user attempted to rename the file system's root folder.
    case cannotRenameRoot
    /// A rename operation failed with an underlying system error.
    case renameFailed(Error)
    /// A move operation failed with an underlying system error.
    case moveFailed(Error)
    /// A copy operation failed with an underlying system error.
    case copyFailed(Error)
    /// A delete operation failed with an underlying system error.
    case deleteFailed(Error)
    /// A search path couldn't be resolved within a given domain.
    case unresolvedSearchPath(
        FileManager.SearchPathDirectory,
        domain: FileManager.SearchPathDomainMask
    )
}

/// Enum listing reasons that a write operation could fail.
public enum WriteErrorReason : Sendable{
    /// An empty path was given when writing or creating a location.
    case emptyPath
    /// A folder couldn't be created because of an underlying system error.
    case folderCreationFailed(Error)
    /// A file couldn't be created.
    case fileCreationFailed
    /// A file couldn't be written to because of an underlying system error.
    case writeFailed(Error)
    /// Failed to encode a string into binary data.
    case stringEncodingFailed(String)
}

/// Enum listing reasons that a read operation could fail.
public enum ReadErrorReason : Sendable{
    /// A file couldn't be read because of an underlying system error.
    case readFailed(Error)
    /// Failed to decode a given set of data into a string.
    case stringDecodingFailed
    /// Encountered a string that doesn't contain an integer.
    case notAnInt(String)
}

/// Error thrown by location operations - such as find, move, copy and delete.
public typealias LocationError = FilesError<LocationErrorReason>
/// Error thrown by write operations - such as file/folder creation.
public typealias WriteError = FilesError<WriteErrorReason>
/// Error thrown by read operations - such as when reading a file's contents.
public typealias ReadError = FilesError<ReadErrorReason>
