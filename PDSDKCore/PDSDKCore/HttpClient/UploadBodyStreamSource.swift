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

import Foundation

/// A producer-backed upload body is one-shot, not a replayable Data body.
final class UploadBodyStreamSource: @unchecked Sendable {
    private let input: InputStream
    private let beginProducing: () -> Void
    private let lock = NSLock()
    private var hasProvidedBody = false

    init(input: InputStream, beginProducing: @escaping () -> Void) {
        self.input = input
        self.beginProducing = beginProducing
    }

    func takeBodyStream() -> InputStream? {
        lock.lock()
        guard !hasProvidedBody, input.streamStatus == .notOpen else {
            lock.unlock()
            return nil
        }
        // URLSession may ask again before its first callback has opened input.
        // Reserve the one-shot body before invoking producer code.
        hasProvidedBody = true
        lock.unlock()
        beginProducing()
        // Producer failure can invalidate the stream synchronously. Never pass
        // a consumed/failed stream to CFNetwork's unopened-body setup path.
        return input.streamStatus == .notOpen ? input : nil
    }
}
