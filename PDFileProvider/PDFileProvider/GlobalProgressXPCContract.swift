// Copyright (c) 2026 Proton AG
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
#if os(macOS)
import FileProvider
import Foundation
import PDCore

/// Wire contract shared by the app and the File Provider extension.
/// Payloads are transient. Incompatible wire changes require a new service name so the app
/// only discovers an extension that speaks the same protocol.
public enum GlobalProgressXPCContract {
    public static let serviceName = NSFileProviderServiceName("ch.protonmail.drive.global-progress.v1")
    public static let becameActiveNotification = DarwinNotification.Name("\(serviceName.rawValue).became-active")

    public static var serviceInterface: NSXPCInterface { NSXPCInterface(with: GlobalProgressXPCServiceProtocol.self) }
    public static var subscriberInterface: NSXPCInterface { NSXPCInterface(with: GlobalProgressXPCSubscriberProtocol.self) }
}

/// Exported by the extension. `subscribe` is one-way: the current value and every later change arrive
/// through `GlobalProgressXPCSubscriberProtocol` on the same connection, in send order.
@objc public protocol GlobalProgressXPCServiceProtocol {
    func subscribe()
}

/// Exported by the app. `payload` is `GlobalProgress.xpcPayload()`.
@objc public protocol GlobalProgressXPCSubscriberProtocol {
    func globalProgressDidChange(_ payload: Data)
}

public extension GlobalProgress {
    func xpcPayload() throws -> Data {
        try JSONEncoder().encode(WireProgress(self))
    }

    /// Strict: any payload that does not map onto a valid domain value throws.
    init(xpcPayload: Data) throws {
        self = try JSONDecoder().decode(WireProgress.self, from: xpcPayload).domainValue()
    }
}

/// Rejects wire data that cannot represent a supported, valid `GlobalProgress` value.
private struct InvalidWireProgress: Error {}

/// JSON representation used by the versioned XPC service to encode and validate `GlobalProgress`.
private struct WireProgress: Codable {
    /// Known file counts for a counted wire transfer; omitted when counts are unknown.
    struct Files: Codable {
        let total: Int
        let completed: Int
    }

    /// Wire representation of one direction, converted to a validated `TransferProgress` on receipt.
    struct Transfer: Codable {
        let files: Files?
        let totalBytes: Int64
        let completedBytes: Int64

        init(_ progress: GlobalProgress.ActiveTransfer.TransferProgress) {
            switch progress {
            case .counted(let value):
                files = .init(total: value.totalFileCount, completed: value.completedFileCount)
                totalBytes = value.totalByteCount
                completedBytes = value.completedByteCount
            case .uncounted(let value):
                files = nil
                totalBytes = value.totalByteCount
                completedBytes = value.completedByteCount
            }
        }

        func domainValue() throws -> GlobalProgress.ActiveTransfer.TransferProgress {
            typealias TransferProgress = GlobalProgress.ActiveTransfer.TransferProgress
            if let files {
                guard let value = TransferProgress.Counted(
                    totalFileCount: files.total,
                    completedFileCount: files.completed,
                    totalByteCount: totalBytes,
                    completedByteCount: completedBytes
                ) else { throw InvalidWireProgress() }
                return .counted(value)
            }
            guard let value = TransferProgress.Uncounted(
                totalByteCount: totalBytes,
                completedByteCount: completedBytes
            ) else { throw InvalidWireProgress() }
            return .uncounted(value)
        }
    }

    let upload: Transfer?
    let download: Transfer?

    init(_ progress: GlobalProgress) {
        switch progress {
        case .idle:
            upload = nil
            download = nil
        case .active(.upload(let value)):
            upload = .init(value)
            download = nil
        case .active(.download(let value)):
            upload = nil
            download = .init(value)
        case .active(.bidirectional(let upload, let download)):
            self.upload = .init(upload)
            self.download = .init(download)
        }
    }

    func domainValue() throws -> GlobalProgress {
        switch (upload, download) {
        case (nil, nil):
            return .idle
        case (.some(let upload), nil):
            return .active(.upload(try upload.domainValue()))
        case (nil, .some(let download)):
            return .active(.download(try download.domainValue()))
        case (.some(let upload), .some(let download)):
            return .active(.bidirectional(upload: try upload.domainValue(), download: try download.domainValue()))
        }
    }
}

#endif
