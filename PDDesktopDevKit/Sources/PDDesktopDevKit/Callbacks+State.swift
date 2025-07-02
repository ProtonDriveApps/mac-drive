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
import SwiftProtobuf

final class TaskCompletionSource<T> {

    public let functionName: String
    private var myself: TaskCompletionSource<T>?
    private let continuation: CheckedContinuation<T, Swift.Error>

    init(continuation: CheckedContinuation<T, Swift.Error>, functionName: String) {
        self.continuation = continuation
        self.functionName = functionName
        self.myself = self
    }

    func setResult(value: T) {
        continuation.resume(returning: value)
        myself = nil
    }

    func setError(error: Swift.Error) {
        continuation.resume(throwing: error)
        myself = nil
    }

    func setResultError(result: Status?) {
        let error = DDKError(failedFunctionName: "Unexpected result \(result?.rawValue ?? -1) in \(functionName)")
        setError(error: error)
    }

    var unretainedPointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}

final class CallbackCompletionSource<T> {

    var value: T?
    var error: Swift.Error?

    let semaphore: DispatchSemaphore

    init(semaphore: DispatchSemaphore) {
        self.semaphore = semaphore
    }

    func setResult(value: T) {
        self.value = value
        semaphore.signal()
    }

    func setError(error: Swift.Error) {
        self.error = error
        semaphore.signal()
    }

    var unretainedPointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}

final class MessageCallbackSource<T, R> where T: Message {

    private let onMessage: MessageCallback<T, R>

    init(onMessage: @escaping MessageCallback<T, R>) {
        self.onMessage = onMessage
    }

    func onMessageReceived(to value: T) -> R {
        onMessage(value)
    }

    var unretainedPointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}

typealias BytesProgressUpdateSource = MessageCallbackSource<ProgressUpdate, Void>

extension BytesProgressUpdateSource {
    convenience init(onBytesProgressUpdate: @escaping BytesProgressCallback) {
        self.init(onMessage: onBytesProgressUpdate)
    }

    func onProgressUpdated(to progressUpdate: ProgressUpdate) {
        onMessageReceived(to: progressUpdate)
    }
}

typealias ResponseBodyReceivedSource = MessageCallbackSource<RequestResponseBodyResponse, Void>

extension ResponseBodyReceivedSource {
    convenience init(onResponseBodyReceived: @escaping ResponseBodyCallback) {
        self.init(onMessage: onResponseBodyReceived)
    }

    func onResponseBodyReceived(responseBody: RequestResponseBodyResponse) {
        onMessageReceived(to: responseBody)
    }

    var retainedPointer: UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }
}

typealias KeyCacheMissedSource = MessageCallbackSource<KeyCacheMissMessage, Bool>

extension KeyCacheMissedSource {
    convenience init(onKeyCacheMissed: @escaping OnKeyCacheMissCallback) {
        self.init(onMessage: onKeyCacheMissed)
    }

    func onKeyCacheMiss(keyCacheMiss: KeyCacheMissMessage) -> R {
        onMessageReceived(to: keyCacheMiss)
    }

    var retainedPointer: UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }
}

typealias TokensRefreshedSource = MessageCallbackSource<SessionTokens, Void>

extension TokensRefreshedSource {
    convenience init(onTokensRefreshed: @escaping TokensRefreshedCallback) {
        self.init(onMessage: onTokensRefreshed)
    }

    func onTokensRefreshed(tokens: SessionTokens) {
        onMessageReceived(to: tokens)
    }

    var retainedPointer: UnsafeMutableRawPointer {
        Unmanaged.passRetained(self).toOpaque()
    }
}
