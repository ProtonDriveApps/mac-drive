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

extension UnsafeRawPointer {
    private func retained<T>() -> T where T: AnyObject {
        return Unmanaged<T>.fromOpaque(self).takeRetainedValue()
    }

    private func unretained<T>() -> T where T: AnyObject {
        return Unmanaged<T>.fromOpaque(self).takeUnretainedValue()
    }

    func unretainedTaskCompletion<T>(with: T.Type) -> TaskCompletionSource<T> {
        unretained()
    }

    func unretainedCallbackCompletion<T>(with: T.Type) -> CallbackCompletionSource<T> {
        unretained()
    }

    func unretainedProgressUpdate<T, R>(with: T.Type) -> MessageCallbackSource<T, R> {
        unretained()
    }

    func unretainedBytesProgressUpdate() -> BytesProgressUpdateSource {
        unretained()
    }

    func unretainedResponseBodyReceived() -> ResponseBodyReceivedSource {
        unretained()
    }

    func unretainedKeyCacheMissed() -> KeyCacheMissedSource {
        unretained()
    }
    
    func unretainedTokensRefreshed() -> TokensRefreshedSource {
        unretained()
    }
}

extension UnsafeMutableRawPointer {
    private func retained<T>() -> T where T: AnyObject {
        return Unmanaged<T>.fromOpaque(self).takeRetainedValue()
    }

    private func unretained<T>() -> T where T: AnyObject {
        return Unmanaged<T>.fromOpaque(self).takeUnretainedValue()
    }

    func unretainedTaskCompletion<T>(with: T.Type) -> TaskCompletionSource<T> {
        unretained()
    }

    func unretainedCallbackCompletion<T>(with: T.Type) -> CallbackCompletionSource<T> {
        unretained()
    }

    func unretainedProgressUpdate<T, R>(with: T.Type) -> MessageCallbackSource<T, R> {
        unretained()
    }

    func unretainedBytesProgressUpdate() -> BytesProgressUpdateSource {
        unretained()
    }

    func unretainedResponseBodyReceived() -> ResponseBodyReceivedSource {
        unretained()
    }

    func unretainedKeyCacheMissed() -> KeyCacheMissedSource {
        unretained()
    }
    
    func unretainedTokensRefreshed() -> TokensRefreshedSource {
        unretained()
    }
}
