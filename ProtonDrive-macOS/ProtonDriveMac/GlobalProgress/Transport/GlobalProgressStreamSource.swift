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

/// Implements `GlobalProgressSource` using `GlobalProgressXPCConnection` connections and `GlobalProgressWakeupStream` signals.
///
/// Lifecycle: connect, relay values until an idle value ends the connection, then wait for the extension's
/// wakeup. An unavailable service on initial discovery parks immediately. After a wakeup or a
/// successful connection, failures retry after 1, 5, and 10 seconds; exhaustion clears stale active
/// progress and continues discovery every 30 seconds until the service recovers or observation stops.
@MainActor
struct GlobalProgressStreamSource: GlobalProgressSource {
    /// Owns one worker and its resources; cancellation removes wakeups before releasing the connection.
    @MainActor
    private final class Lifetime {
        /// The consuming worker, cleared when the lifetime ends.
        var task: Task<Void, Never>?
        /// The current connection, or nil while discovering or parked.
        var connection: Connection?
        /// One-time wakeup cleanup; nil means this lifetime has ended.
        private var wakeupCancellation: WakeupCancellation?

        init(wakeupCancellation: WakeupCancellation) {
            self.wakeupCancellation = wakeupCancellation
        }

        /// Ends only the current connection, leaving wakeup observation and the worker alive.
        func invalidateConnection() {
            let currentConnection = connection
            connection = nil
            currentConnection?.invalidate()
        }

        /// Removes wakeups first, then cancels the worker and releases its current connection.
        func cancel() {
            guard let wakeupCancellation else { return }
            self.wakeupCancellation = nil
            wakeupCancellation.cancel()
            task?.cancel()
            task = nil
            invalidateConnection()
        }

        /// Thread-safe listener removal may run synchronously on the consumer's executor.
        final class WakeupCancellation: @unchecked Sendable {
            private let lock = NSLock()
            private var onCancellation: (() -> Void)?

            init(onCancellation: @escaping () -> Void) {
                self.onCancellation = onCancellation
            }

            func cancel() {
                lock.lock()
                defer { lock.unlock() }
                onCancellation?()
                onCancellation = nil
            }
        }
    }

    /// Incoming values and invalidation for one XPC connection, held by this stream's `Lifetime`.
    struct Connection {
        let values: AsyncThrowingStream<GlobalProgress, Error>
        let invalidate: () -> Void
    }

    private let retryDelays: [Duration]
    private let recoveryDelay: Duration = .seconds(30)

    init(retryDelays: [Duration]) {
        self.retryDelays = retryDelays
    }

    init() {
        self.init(retryDelays: [.seconds(1), .seconds(5), .seconds(10)])
    }

    @MainActor
    func makeProgressStream(
        for domain: NSFileProviderDomain
    ) -> AsyncStream<GlobalProgress> {
        makeProgressStream(
            onConnect: { try await GlobalProgressXPCConnection.makeConnection(domain: domain) },
            onWakeup: { GlobalProgressWakeupStream.makeWakeupStream() }
        )
    }

    @MainActor
    func makeProgressStream(
        onConnect: @escaping @MainActor () async throws -> Connection,
        onWakeup: @escaping @MainActor () -> GlobalProgressWakeupStream.Registration,
        onSleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        onWorkerFinished: @escaping @MainActor () -> Void = {}
    ) -> AsyncStream<GlobalProgress> {
        AsyncStream { continuation in
            let registration = onWakeup()
            let wakeupCancellation = Lifetime.WakeupCancellation(
                onCancellation: registration.cancel
            )
            let lifetime = Lifetime(wakeupCancellation: wakeupCancellation)
            let task = Task { @MainActor in
                defer {
                    lifetime.cancel()
                    continuation.finish()
                    onWorkerFinished()
                }
                await relayProgress(
                    to: continuation,
                    wakeups: registration.values,
                    lifetime: lifetime,
                    onConnect: onConnect,
                    onSleep: onSleep
                )
            }
            lifetime.task = task
            continuation.onTermination = { _ in
                // Fence removal before cancelling the worker, synchronously: a discovery that is
                // already resuming must see cancellation before configuring/subscribing to XPC.
                wakeupCancellation.cancel()
                task.cancel()
                Task { @MainActor in lifetime.cancel() }
            }
        }
    }

    @MainActor
    private func relayProgress(
        to continuation: AsyncStream<GlobalProgress>.Continuation,
        wakeups: AsyncStream<Void>,
        lifetime: Lifetime,
        onConnect: @escaping @MainActor () async throws -> Connection,
        onSleep: @escaping (Duration) async throws -> Void
    ) async {
        var last: GlobalProgress?
        @MainActor func deliver(_ value: GlobalProgress) {
            guard !Task.isCancelled, value != last else { return }
            last = value
            continuation.yield(value)
        }

        /// Serve until idle or cancellation, retrying slowly after the initial budget is exhausted.
        @MainActor func serve(afterWakeup: Bool) async {
            var retryUnavailable = afterWakeup
            var failures = 0
            var reportedExhaustion = false
            while !Task.isCancelled {
                if failures > retryDelays.count, !reportedExhaustion {
                    reportedExhaustion = true
                    let hadStaleValue = last != nil && last != .idle
                    if hadStaleValue { deliver(.idle) }
                    Log.warning(
                        "Global progress unavailable after \(failures) attempts —"
                            + " continuing slow recovery attempts"
                            + " (cleared a stale active value: \(hadStaleValue))",
                        domain: .application,
                        sendToSentryIfPossible: true
                    )
                }
                if failures > 0 {
                    let delay = failures <= retryDelays.count
                        ? retryDelays[failures - 1]
                        : recoveryDelay
                    Log.debug(
                        "Retrying global progress connection in \(delay)",
                        domain: .application
                    )
                    do {
                        try await onSleep(delay)
                    } catch {
                        return
                    }
                }
                if Task.isCancelled { return }
                let connection: Connection
                do {
                    connection = try await onConnect()
                } catch is CancellationError {
                    return
                } catch GlobalProgressXPCConnection.Failure.unavailable where !retryUnavailable {
                    Log.debug(
                        "Global progress service not running at startup — waiting for activity",
                        domain: .application
                    )
                    return
                } catch {
                    failures = min(failures + 1, retryDelays.count + 1)
                    Log.debug(
                        "Global progress connection attempt \(failures) failed",
                        domain: .application
                    )
                    continue
                }
                guard !Task.isCancelled else {
                    connection.invalidate()
                    return
                }
                lifetime.connection = connection
                retryUnavailable = true
                var received = false
                do {
                    defer { lifetime.invalidateConnection() }
                    for try await value in connection.values {
                        guard !Task.isCancelled else { return }
                        received = true
                        deliver(value)
                        if value == .idle {
                            Log.debug(
                                "Global progress connection ended at idle —"
                                    + " parking until the extension signals activity",
                                domain: .application
                            )
                            return
                        }
                    }
                } catch {
                    Log.debug(
                        "Global progress connection ended (\(String(describing: type(of: error)))"
                            + "; delivered values: \(received))",
                        domain: .application
                    )
                }
                if Task.isCancelled { return }
                failures = received ? 0 : min(failures + 1, retryDelays.count + 1)
                if received {
                    reportedExhaustion = false
                    // Deliberately .info, not .debug: a productive connection resets the retry
                    // budget, so a connection that keeps breaking after one value
                    // reconnects forever without backoff and never trips the exhaustion
                    // warning below. Release builds drop .debug, so this must not be one.
                    Log.info(
                        "Reconnecting global progress immediately —"
                            + " the connection broke after delivering values",
                        domain: .application
                    )
                }
            }
        }

        var wakeupIterator = wakeups.makeAsyncIterator()
        await serve(afterWakeup: false)
        while !Task.isCancelled, await wakeupIterator.next() != nil {
            Log.info(
                "Extension signalled activity — reconnecting global progress",
                domain: .application
            )
            await serve(afterWakeup: true)
        }
    }

}
