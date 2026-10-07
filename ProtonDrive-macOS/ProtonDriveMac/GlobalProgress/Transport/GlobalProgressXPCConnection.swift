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
import FileProvider
import Foundation
import PDCore
import PDFileProvider

/// Discovers the extension's service and creates a fresh XPC connection for `GlobalProgressStreamSource`.
enum GlobalProgressXPCConnection {
    enum Failure: Error {
        case unavailable
        case invalidProxy
        case interrupted
        case invalidated
    }

    @MainActor
    static func makeConnection(
        domain: NSFileProviderDomain
    ) async throws -> GlobalProgressStreamSource.Connection {
        try await makeConnection(connectionFactory: {
            guard let manager = NSFileProviderManager(for: domain),
                  let service = try await manager.service(named: GlobalProgressXPCContract.serviceName, for: .rootContainer)
            else {
                // Expected before the extension launches. Initial discovery waits for an activity
                // notification; discovery after activity uses bounded retries.
                Log.debug(
                    "Global progress service unavailable",
                    domain: .application
                )
                throw Failure.unavailable
            }
            try Task.checkCancellation()
            return try await service.fileProviderConnection()
        })
    }

    @MainActor
    static func makeConnection(
        connectionFactory: @MainActor () async throws -> NSXPCConnection
    ) async throws -> GlobalProgressStreamSource.Connection {
        try Task.checkCancellation()
        let connection = try await connectionFactory()
        guard !Task.isCancelled else {
            connection.invalidate()
            throw CancellationError()
        }

        let (values, continuation) = AsyncThrowingStream<GlobalProgress, Error>.makeStream()
        connection.remoteObjectInterface = GlobalProgressXPCContract.serviceInterface
        connection.exportedInterface = GlobalProgressXPCContract.subscriberInterface
        connection.exportedObject = Subscriber { payload in
            do {
                continuation.yield(try GlobalProgress(xpcPayload: payload))
            } catch {
                // Fixed message: only the `error:` object is sanitized before reaching Sentry.
                Log.error(
                    "Malformed global progress payload — ending the connection",
                    error: error,
                    domain: .application
                )
                continuation.finish(throwing: error) // malformed wire data ends the connection; retry policy takes over
            }
        }
        connection.interruptionHandler = {
            Log.debug("Global progress connection interrupted", domain: .application)
            continuation.finish(throwing: Failure.interrupted)
        }
        connection.invalidationHandler = {
            Log.debug("Global progress connection invalidated", domain: .application)
            continuation.finish(throwing: Failure.invalidated)
        }
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.finish(throwing: $0) }
        guard let service = proxy as? GlobalProgressXPCServiceProtocol else {
            connection.invalidate()
            // File-only: the two sides ship together, so a mismatched interface is a build-time
            // contract break rather than a field condition worth alerting on.
            Log.error(
                "Global progress remote proxy does not conform to the service protocol",
                error: Failure.invalidProxy,
                domain: .application,
                sendToSentryIfPossible: false
            )
            throw Failure.invalidProxy
        }
        service.subscribe()
        return .init(values: values, invalidate: { connection.invalidate() })
    }

    /// The app's exported XPC endpoint, forwarding pushed payloads into the connection's value stream.
    private final class Subscriber: NSObject, GlobalProgressXPCSubscriberProtocol {
        private let onPayloadReceived: (Data) -> Void

        init(onPayloadReceived: @escaping (Data) -> Void) {
            self.onPayloadReceived = onPayloadReceived
        }

        func globalProgressDidChange(_ payload: Data) {
            onPayloadReceived(payload)
        }
    }
}
