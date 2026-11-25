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

import CoreData
import Foundation
import PDClient
@preconcurrency import PDCore
import ProtonDriveSDK

struct SDKOperationStreamEngine {
    let metadataUpdater: MetadataUpdaterProtocol

    /// Bridges a callback based SDK operation into a stream of its items.
    /// - Parameter onCancel: Called when the consumer drops the stream before it finishes,
    ///   for SDK operations that have to be cancelled explicitly.
    func operationStream<Item: Sendable>(
        invoke: @escaping @Sendable (@escaping @Sendable (Result<Item, Error>) -> Void) async throws -> Void,
        onCancel: (@Sendable () async -> Void)? = nil
    ) -> AsyncThrowingStream<Item, Error> {
        bracketedStream(of: Item.self, onCancel: onCancel) { continuation in
            let (itemStream, cancelBridgeTask) = SDKEnumerationStreamBridge.stream(invoke: invoke)
            defer { cancelBridgeTask() }

            do {
                for try await item in itemStream {
                    continuation.yield(item)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func stream(
        operation: NodeBatchOperation,
        nodes: [SDKNodeUid],
        cancellationToken: UUID,
        moc: NSManagedObjectContext,
        invoke: @escaping @Sendable (UUID, @escaping NodeResultCallback) async throws -> Void
    ) -> AsyncThrowingStream<NodeOperationStreamEvent, Error> {
        if nodes.isEmpty {
            return AsyncThrowingStream { continuation in
                continuation.yield(.completed(error: nil))
                continuation.finish()
            }
        }

        let metadataUpdater = self.metadataUpdater
        return bracketedStream(of: NodeOperationStreamEvent.self) { continuation in
            let (nodeResultStream, cancelBridgeTask) = SDKEnumerationStreamBridge.stream { callback in
                try await invoke(cancellationToken, callback)
            }
            // When task is finished, make sure `cancelBridgeTask` is stopped
            defer { cancelBridgeTask() }

            switch operation {
            case .trash:
                await consumeResults(
                    stream: nodeResultStream,
                    moc: moc,
                    applyFailureLogMessage: "Failed to apply local trash results",
                    continuation: continuation
                ) { batch, moc in
                    try await metadataUpdater.applyTrashResults(batch, moc: moc)
                }
            case .restore:
                await consumeResults(
                    stream: nodeResultStream,
                    moc: moc,
                    applyFailureLogMessage: "Failed to apply local restore results",
                    continuation: continuation
                ) { batch, moc in
                    try await metadataUpdater.finishRestoreIOSNodes(results: batch, moc: moc)
                    return []
                }
            case .delete:
                await consumeResults(
                    stream: nodeResultStream,
                    moc: moc,
                    applyFailureLogMessage: "Failed to apply local delete results",
                    continuation: continuation
                ) { batch, _ in
                    if let error = batch.filter({ $0.error != nil }).first?.error {
                        throw error
                    }
                    return []
                }
            }
        }
    }

    func streamNodeResults(
        moc: NSManagedObjectContext,
        applyFailureLogMessage: String,
        invoke: @escaping @Sendable (@escaping NodeResultCallback) async throws -> Void,
        applyBatch: @escaping ([NodeResult], NSManagedObjectContext) async throws -> [AnyVolumeIdentifier],
        onCancel: (@Sendable () async -> Void)? = nil
    ) -> AsyncThrowingStream<NodeOperationStreamEvent, Error> {
        bracketedStream(of: NodeOperationStreamEvent.self, onCancel: onCancel) { continuation in
            let (nodeResultStream, cancelBridgeTask) = SDKEnumerationStreamBridge.stream { callback in
                try await invoke(callback)
            }
            defer { cancelBridgeTask() }

            await consumeResults(
                stream: nodeResultStream,
                moc: moc,
                applyFailureLogMessage: applyFailureLogMessage,
                continuation: continuation,
                applyBatch: applyBatch
            )
        }
    }
}

extension SDKOperationStreamEngine {
    /// Bare beginOperation/endOperation pair: stream lifetime can outlive any single closure,
    /// so we hand-roll the bracketing instead of using `withOperation`. The capture below holds
    /// `metadataUpdater` strongly so `endOperation` fires even if the caller is released first.
    /// `produce` is responsible for finishing the continuation.
    private func bracketedStream<Output>(
        of outputType: Output.Type,
        onCancel: (@Sendable () async -> Void)? = nil,
        produce: @escaping (AsyncThrowingStream<Output, Error>.Continuation) async -> Void
    ) -> AsyncThrowingStream<Output, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: outputType)

        let metadataUpdater = self.metadataUpdater
        metadataUpdater.beginOperation()

        let task = Task {
            await produce(continuation)
        }

        continuation.onTermination = { @Sendable termination in
            // Stop the background work when the consumer drops the stream or it finishes
            task.cancel()
            if case .cancelled = termination, let onCancel {
                Task { await onCancel() }
            }
            metadataUpdater.endOperation(context: EndOperationContext())
        }
        return stream
    }

    private func consumeResults(
        stream: AsyncThrowingStream<NodeResult, Error>,
        moc: NSManagedObjectContext,
        applyFailureLogMessage: String,
        continuation: AsyncThrowingStream<NodeOperationStreamEvent, Error>.Continuation,
        applyBatch: @escaping ([NodeResult], NSManagedObjectContext) async throws -> [AnyVolumeIdentifier]
    ) async {
        // The SDK yields results one by one; batch them so we don't hop to the
        // context's queue on every item
        let firstError = FirstErrorBox()
        let flusher = DebouncedBatchBuffer(
            configuration: DebouncedBatchBufferConfiguration.nodeOperationFlush
        ) { batch in
            do {
                let affectedIdentifiers = try await applyBatch(batch, moc)
                continuation.yield(.nodeResults(results: batch, affectedIdentifiers: affectedIdentifiers))
            } catch {
                Log.error(applyFailureLogMessage, error: error, domain: .sdk)
                await firstError.updateErrorIfNeeded(error: error)
            }
        }

        do {
            for try await result in stream {
                await firstError.updateErrorIfNeeded(error: Self.nodeOperationError(from: result))
                await flusher.append(result)
            }
        } catch {
            await firstError.updateErrorIfNeeded(error: error)
        }
        await flusher.finish()
        continuation.yield(.completed(error: await firstError.value))
        continuation.finish()
    }

    private static func nodeOperationError(from result: NodeResult) -> Error? {
        guard let error = result.error else { return nil }
        return error.primaryCode == APIErrorCodes.itemOrItsParentDeletedErrorCode.rawValue ? nil : error
    }
}

private actor FirstErrorBox {
    private(set) var value: Error?

    func updateErrorIfNeeded(error: Error?) {
        self.value = value ?? error
    }
}
