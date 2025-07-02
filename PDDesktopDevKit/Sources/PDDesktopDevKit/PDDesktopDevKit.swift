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
import ProtonDriveSdk
import SwiftProtobuf

public typealias ObjectHandle = Int

// MARK: - Helper extensions

extension Status {
    init(result: Int32?) {
        self.init(rawValue: Int(result ?? -1))!
    }
}

extension ByteArray {
    public func to<T: SwiftProtobuf.Message>(_ to: T.Type) -> T {
        guard let pointer else { return T() }
        let data = Data(bytes: pointer, count: length)
        return (try? T(serializedBytes: data)) ?? T()
    }
}

public extension Progress {
    func update(from progressUpdate: ProgressUpdate) throws {
        // we're not using the bytesCompleted directly because these are encrypted size bytes,
        // and progress is tracking the clear size bytes
        guard progressUpdate.bytesInTotal > 0, progressUpdate.bytesInTotal > progressUpdate.bytesCompleted else {
            throw DDKError.nonActionable(
                message: "Incorrect progress numbers: \(progressUpdate.bytesCompleted)/\(progressUpdate.bytesInTotal)",
                inner: Error(),
                failedFunctionName: "Progress.progressUpdate")
        }
        
        assert(progressUpdate.bytesInTotal > 0)
        if progressUpdate.bytesInTotal > 0 {
            let workDoneFraction = Double(progressUpdate.bytesCompleted) / Double(progressUpdate.bytesInTotal)
            completedUnitCount = Int64(Double(totalUnitCount) * workDoneFraction)
        }
    }
}

final class ProtoCallback {
    final class One<T> {
        let callback: (T) -> Void
        init(callback: @escaping (T) -> Void) {
            self.callback = callback
        }
    }
    final class Three<T, U, V> {
        let callback: (T, U, V) -> Void
        init(callback: @escaping (T, U, V) -> Void) {
            self.callback = callback
        }
    }
}

public extension OperationIdentifier {
    static func forFileDownload(fileIdentity: NodeIdentity) -> OperationIdentifier {
        OperationIdentifier.with {
            $0.type = .download
            $0.identifier = fileIdentity.textFormatString()
        }
    }

    static func forFileUpload(fileUrl: URL) -> OperationIdentifier {
        OperationIdentifier.with {
            $0.type = .fileUpload
            $0.identifier = fileUrl.path()
        }
    }

    static func forRevisionUpload(fileIdentity: NodeIdentity) -> OperationIdentifier {
        OperationIdentifier.with {
            $0.type = .revisionUpload
            $0.identifier = fileIdentity.textFormatString()
        }
    }
}

// MARK: - Closure helpers

public typealias MessageCallback<T, R> = (T) -> R where T: SwiftProtobuf.Message
/// Called when there is a progress update. Receives a ProgressUpdate object with completed and total bytes.
/// Depending on the context, this may be the number of bytes transmitted up or down.
public typealias BytesProgressCallback = MessageCallback<ProgressUpdate, Void>
public typealias ResponseBodyCallback = MessageCallback<RequestResponseBodyResponse, Void>
public typealias OnKeyCacheMissCallback = MessageCallback<KeyCacheMissMessage, Bool>
public typealias TokensRefreshedCallback = MessageCallback<SessionTokens, Void>

func invokeDDK<Request, Response>(
    calledFrom functionName: String = #function,
    objectHandle: Int,
    request: Request,
    cancellationTokenSource: CancellationTokenSource,
    functionInvocation: @escaping (Int, ByteArray, AsyncCallback) -> Int32,
    successCallback: @convention(c) (UnsafeRawPointer?, ByteArray) -> Void = { _, _ in }
) async throws -> Response where Request: Message {
    return try await withCheckedThrowingContinuation { continuation in
        let taskCompletionSource = TaskCompletionSource<Response>(continuation: continuation, functionName: functionName)

        let tcsPtr = taskCompletionSource.unretainedPointer

        let callback = AsyncCallback(
            state: tcsPtr,
            on_success: successCallback,
            on_failure: errorCallbackForContinuation,
            cancellation_token_source_handle: cancellationTokenSource.handle
        )

        do {
            let result = try safeAccess(request) {
                functionInvocation(objectHandle, $0, callback)
            }.asStatus

            guard result == .ok else {
                tcsPtr.unretainedTaskCompletion(with: Response.self)
                    .setResultError(result: result)
                return
            }
        } catch {
            tcsPtr.unretainedTaskCompletion(with: Response.self)
                .setResultError(result: Status.UNRECOGNIZED(-2))
        }
    }
}

func invokeDDKWithoutRequest<Response>(
    calledFrom functionName: String = #function,
    objectHandle: Int,
    cancellationTokenSource: CancellationTokenSource,
    functionInvocation: @escaping (Int, AsyncCallback) -> Int32,
    successCallback: @convention(c) (UnsafeRawPointer?, ByteArray) -> Void
) async throws -> Response {
    return try await withCheckedThrowingContinuation { continuation in
        let taskCompletionSource = TaskCompletionSource<Response>(continuation: continuation, functionName: functionName)

        let tcsPtr = taskCompletionSource.unretainedPointer

        let callback = AsyncCallback(
            state: tcsPtr,
            on_success: successCallback,
            on_failure: errorCallbackForContinuation,
            cancellation_token_source_handle: cancellationTokenSource.handle
        )

        let result = functionInvocation(objectHandle, callback).asStatus

        guard result == .ok else {
            tcsPtr.unretainedTaskCompletion(with: Response.self)
                .setResultError(result: result)
            return
        }
    }
}

// swiftlint:disable:next function_parameter_count
func invokeDDKWithResponseBodyAndKeyCacheMissAndTokenRefreshed<Request, Response>(
    calledFrom functionName: String = #function,
    objectHandle: Int,
    onResponseBodyReceived: @escaping ResponseBodyCallback,
    onKeyCacheMiss: @escaping OnKeyCacheMissCallback,
    onTokensRefreshed: @escaping TokensRefreshedCallback,
    cancellationTokenSource: CancellationTokenSource,
    request: Request,
    functionInvocation: @escaping (Int, ByteArray, Callback, BooleanCallback, Callback, AsyncCallback) -> Int32,
    successCallback: @convention(c) (UnsafeRawPointer?, ByteArray) -> Void = { _, _ in }
) async throws -> Response where Request: Message {
    let response = try await withCheckedThrowingContinuation { continuation in
        let taskCompletionSource = TaskCompletionSource<Response>(continuation: continuation, functionName: functionName)
        let responseReceivedSource = ResponseBodyReceivedSource(onResponseBodyReceived: onResponseBodyReceived)
        let keyCacheMissedSource = KeyCacheMissedSource(onKeyCacheMissed: onKeyCacheMiss)
        let tokensRefreshedSource = TokensRefreshedSource(onTokensRefreshed: onTokensRefreshed)

        let tcsPtr = taskCompletionSource.unretainedPointer
        let rbrPtr = responseReceivedSource.retainedPointer
        let kcmsPtr = keyCacheMissedSource.retainedPointer
        let tokPtr = tokensRefreshedSource.retainedPointer

        let responseBodyCallback = ProtonDriveSdk.Callback(
            state: rbrPtr,
            callback: responseBodyCallback
        )

        let keyCacheMissedCallback = ProtonDriveSdk.BooleanCallback(
            state: kcmsPtr,
            callback: onKeyCacheMissedCallback
        )
        
        let tokensRefreshedCallback = ProtonDriveSdk.Callback(
            state: tokPtr,
            callback: tokensRefreshedCallback
        )

        let asyncCallback = AsyncCallback(
            state: tcsPtr,
            on_success: successCallback,
            on_failure: errorCallbackForContinuation,
            cancellation_token_source_handle: cancellationTokenSource.handle
        )

        do {
            let result = try safeAccess(request) {
                functionInvocation(
                    objectHandle, $0, responseBodyCallback, keyCacheMissedCallback, tokensRefreshedCallback, asyncCallback
                )
            }.asStatus

            guard result == .ok else {
                tcsPtr.unretainedTaskCompletion(with: Response.self)
                      .setResultError(result: result)
                return
            }
        } catch {
            tcsPtr.unretainedTaskCompletion(with: Response.self)
                  .setResultError(result: Status.UNRECOGNIZED(-2))
        }
    }
    return response
}

func invokeDDKWithProgress<Request, Response>(
    calledFrom functionName: String = #function,
    objectHandle: Int,
    onBytesProgressUpdate: @escaping BytesProgressCallback,
    cancellationTokenSource: CancellationTokenSource,
    request: Request,
    functionInvocation: @escaping (Int, ByteArray, AsyncCallbackWithProgress) -> Int32,
    successCallback: @convention(c) (UnsafeRawPointer?, ByteArray) -> Void = { _, _ in }
) async throws -> Response where Request: Message {
    let progressUpdateSource = BytesProgressUpdateSource(onBytesProgressUpdate: onBytesProgressUpdate)
    let response = try await withCheckedThrowingContinuation { continuation in
        let taskCompletionSource = TaskCompletionSource<Response>(continuation: continuation, functionName: functionName)
        
        let tcsPtr = taskCompletionSource.unretainedPointer
        let pusPtr = progressUpdateSource.unretainedPointer

        let asyncCallback = AsyncCallback(
            state: tcsPtr,
            on_success: successCallback,
            on_failure: errorCallbackForContinuation,
            cancellation_token_source_handle: cancellationTokenSource.handle
        )
        let progressCallback = ProtonDriveSdk.Callback(
            state: pusPtr,
            callback: byteProgressCallback
        )
        let callback = AsyncCallbackWithProgress(
            async_callback: asyncCallback,
            progress_callback: progressCallback
        )

        do {
            let result = try safeAccess(request) {
                functionInvocation(objectHandle, $0, callback)
            }.asStatus

            guard result == .ok else {
                tcsPtr.unretainedTaskCompletion(with: Response.self)
                      .setResultError(result: result)
                return
            }
        } catch {
            tcsPtr.unretainedTaskCompletion(with: Response.self)
                  .setResultError(result: Status.UNRECOGNIZED(-2))
        }
    }
    // we need to keep this alive until the await call finishes
    _ = progressUpdateSource
    return response
}

func safeAccess<T>(_ message: Message, closure: (ByteArray) -> T) throws -> T {
    let serializedData = try message.serializedData()
    let result = serializedData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        let bufferPointer = bytes.bindMemory(to: UInt8.self)
        let unsafePointer = bufferPointer.baseAddress!
        let byteArray = ByteArray(pointer: unsafePointer, length: serializedData.count)
        return closure(byteArray)
    }
    return result
}

let errorCallbackForContinuation: @convention(c) (UnsafeRawPointer?, ByteArray) -> Void = { tcsPtr, errorBytes in
    guard let tcs = tcsPtr?.unretainedTaskCompletion(with: ProtonApiSession.self) else { return }
    let error = DDKError(errorResponse: errorBytes.to(PDDesktopDevKit.Error.self), failedFunctionName: tcs.functionName)
    tcs.setError(error: error)
}

let errorCallbackForSemaphore: @convention(c) (UnsafeRawPointer?, ByteArray) -> Void = { tcsPtr, errorBytes in
    guard let tcs = tcsPtr?.unretainedTaskCompletion(with: ProtonApiSession.self) else { return }
    let error = DDKError(errorResponse: errorBytes.to(PDDesktopDevKit.Error.self), failedFunctionName: tcs.functionName)
    tcs.setError(error: error)
}

let byteProgressCallback: @convention(c) (UnsafeRawPointer?, ByteArray) -> Void = { pusPtr, progressBytes in
    guard let pus = pusPtr?.unretainedBytesProgressUpdate() else { return }
    let progressUpdate = progressBytes.to(ProgressUpdate.self)
    pus.onProgressUpdated(to: progressUpdate)
}

let responseBodyCallback: @convention(c) (UnsafeRawPointer?, ByteArray) -> Void = { rbrPtr, responseBody in
    guard let rbt = rbrPtr?.unretainedResponseBodyReceived() else { return }
    let requestResponseBody = responseBody.to(RequestResponseBodyResponse.self)
    rbt.onMessageReceived(to: requestResponseBody)
}

let onKeyCacheMissedCallback: @convention(c) (UnsafeRawPointer?, ByteArray) -> Bool = { kcmPtr, keyCacheMissBytes in
    guard let kcm = kcmPtr?.unretainedKeyCacheMissed() else { return false }
    let keyCacheMiss = keyCacheMissBytes.to(KeyCacheMissMessage.self)
    return kcm.onKeyCacheMiss(keyCacheMiss: keyCacheMiss)
}

let tokensRefreshedCallback: @convention(c) (UnsafeRawPointer?, ByteArray) -> Void = { tokPtr, tokensBytes in
    guard let tok = tokPtr?.unretainedTokensRefreshed() else { return }
    let tokens = tokensBytes.to(SessionTokens.self)
    tok.onTokensRefreshed(tokens: tokens)
}
