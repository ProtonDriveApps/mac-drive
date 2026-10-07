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

/// Owned by `FileProviderExtension`; relays `GlobalProgressProvider` updates through XPC sessions on one serial queue.
public final class GlobalProgressXPCServiceSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate {
    public let serviceName = GlobalProgressXPCContract.serviceName
    public let isRestricted = true

    /// Transport operations for one app connection.
    struct Connection {
        let send: (Data) -> Void
        let invalidate: () -> Void
        /// Runs after earlier local sends, without guaranteeing remote receipt.
        let sendBarrier: (@escaping () -> Void) -> Void
    }

    /// Subscription and delivery state for one app connection.
    private final class SessionState {
        let connection: Connection
        var isSubscribed = false
        /// Terminal idle was sent; further values must be suppressed.
        var isTerminal = false
        /// Last value sent to this subscriber, used to suppress duplicates.
        var lastSent: GlobalProgress?
        init(_ connection: Connection) {
            self.connection = connection
        }
    }

    /// Weak forwarding avoids a cycle between the source and its exported connections.
    private final class Service: NSObject, GlobalProgressXPCServiceProtocol {
        weak var source: GlobalProgressXPCServiceSource?
        func subscribe() {
            guard let connection = NSXPCConnection.current() else { return }
            source?.subscribe(ObjectIdentifier(connection))
        }
    }

    private let queue: DispatchQueue
    private let progressProvider: any GlobalProgressProvider
    private let listener: any GlobalProgressServiceListener
    private let wakeupNotifier: any GlobalProgressWakeupNotifier
    private let service = Service()
    private var latest = GlobalProgress.idle
    private var sessions: [ObjectIdentifier: SessionState] = [:]
    private var isShutDown = false
    private var isServing = false

    public convenience init(manager: NSFileProviderManager) {
        let queue = DispatchQueue(label: "ch.protonmail.drive.global-progress.service")
        self.init(
            queue: queue,
            progressProvider: FoundationProgressProvider(
                downloadProgress: manager.globalProgress(for: .downloading),
                uploadProgress: manager.globalProgress(for: .uploading),
                queue: queue
            ),
            listener: NSXPCListener.anonymous(),
            wakeupNotifier: DarwinGlobalProgressWakeupNotifier(notificationCenter: .shared)
        )
    }

    /// Internal platform seams allow deterministic contracts without a live XPC process.
    /// The provider delivers on `queue` and establishes its initial value before start returns.
    init(
        queue: DispatchQueue,
        progressProvider: any GlobalProgressProvider,
        listener: any GlobalProgressServiceListener,
        wakeupNotifier: any GlobalProgressWakeupNotifier
    ) {
        self.queue = queue
        self.listener = listener
        self.progressProvider = progressProvider
        self.wakeupNotifier = wakeupNotifier
        super.init()
        service.source = self
        listener.delegate = self
        progressProvider.startObservingProgress { [weak self] value in
            self?.publish(value)
        }
    }

    deinit {
        progressProvider.stopObservingProgress()
        listener.invalidate()
    }

    /// Call after publishing this source through `supportedServiceSources`.
    public func startServing() {
        queue.async {
            guard !self.isShutDown, !self.isServing else { return }
            self.isServing = true
            self.listener.resume()
            let isActive: Bool
            if case .active = self.latest {
                self.wakeupNotifier.postWakeup()
                isActive = true
            } else {
                isActive = false
            }
            Log.info(
                "Global progress service listening — latest \(self.latest.logDescription),"
                    + " posted wakeup: \(isActive)",
                domain: .fileProvider
            )
        }
    }

    public func shutdown() {
        queue.async {
            guard !self.isShutDown else { return }
            self.isShutDown = true
            Log.info(
                "Global progress service shutting down — \(self.sessions.count) session(s)",
                domain: .fileProvider
            )
            self.progressProvider.stopObservingProgress()
            guard !self.sessions.isEmpty else { return self.listener.invalidate() }
            for (id, session) in self.sessions {
                if session.isSubscribed, !session.isTerminal { self.send(.idle, to: session) }
                // A barrier orders local sends, not remote receipt. Capture self until shutdown completes.
                session.connection.sendBarrier {
                    self.queue.async { self.removeConnection(id, invalidate: true) }
                }
            }
        }
    }

    public func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        return listener.endpoint
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let id = ObjectIdentifier(connection)
        connection.exportedInterface = GlobalProgressXPCContract.serviceInterface
        connection.exportedObject = service
        connection.remoteObjectInterface = GlobalProgressXPCContract.subscriberInterface
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            queue.async { self.removeConnection(id, invalidate: false) }
        }
        let transport = Connection(
            send: { payload in
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    // A dead client is routine: the app disconnects when idle.
                    Log.debug(
                        "Global progress send failed, invalidating connection (\(String(describing: type(of: error))))",
                        domain: .fileProvider
                    )
                    connection.invalidate()
                }
                guard let subscriber = proxy as? GlobalProgressXPCSubscriberProtocol else {
                    Log.warning(
                        "Global progress subscriber proxy does not conform, invalidating",
                        domain: .fileProvider
                    )
                    return connection.invalidate()
                }
                subscriber.globalProgressDidChange(payload)
            },
            invalidate: { connection.invalidate() },
            sendBarrier: { connection.scheduleSendBarrierBlock($0) }
        )
        acceptConnection(
            id,
            connection: transport
        )
        connection.resume()
        return true
    }

    func acceptConnection(
        _ id: ObjectIdentifier,
        connection: Connection
    ) {
        queue.async {
            guard !self.isShutDown else {
                Log.info(
                    "Rejecting global progress connection — service is shut down",
                    domain: .fileProvider
                )
                return connection.invalidate()
            }
            self.sessions[id] = SessionState(connection)
            Log.info(
                "Accepted global progress connection — \(self.sessions.count) session(s)",
                domain: .fileProvider
            )
        }
    }

    func subscribe(_ id: ObjectIdentifier) {
        queue.async {
            guard !self.isShutDown, let session = self.sessions[id], !session.isSubscribed else {
                Log.info(
                    "Ignoring global progress subscribe — shut down: \(self.isShutDown),"
                        + " known session: \(self.sessions[id] != nil)",
                    domain: .fileProvider
                )
                return
            }
            session.isSubscribed = true
            Log.info(
                "Global progress subscriber attached — replaying \(self.latest.logDescription)",
                domain: .fileProvider
            )
            self.send(self.latest, to: session)
        }
    }

    private func publish(_ value: GlobalProgress) {
        guard !isShutDown else { return }
        let wasIdle = latest == .idle
        latest = value
        if isServing, wasIdle, value != .idle {
            wakeupNotifier.postWakeup()
            Log.debug("Posted global progress wakeup", domain: .fileProvider)
        }
        // Only transitions, never every value: active values arrive at up to 2 Hz.
        if wasIdle != (value == .idle) {
            Log.info("Global progress became \(value.logDescription)", domain: .fileProvider)
        }
        sessions.values.filter { $0.isSubscribed && !$0.isTerminal }.forEach { send(value, to: $0) }
    }

    private func send(
        _ value: GlobalProgress,
        to session: SessionState
    ) {
        guard session.lastSent != value, let payload = try? value.xpcPayload() else { return }
        session.lastSent = value
        session.isTerminal = value == .idle
        session.connection.send(payload)
    }

    private func removeConnection(
        _ id: ObjectIdentifier,
        invalidate: Bool
    ) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if invalidate { session.connection.invalidate() }
        Log.debug(
            "Removed global progress session — \(sessions.count) remaining",
            domain: .fileProvider
        )
        if isShutDown, sessions.isEmpty { listener.invalidate() }
    }
}
