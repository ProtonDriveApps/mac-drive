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
import PDCore
import PDFileProvider

/// Supplies extension activity signals to `GlobalProgressStreamSource`, retaining at most one pending wakeup.
enum GlobalProgressWakeupStream {
    /// Pairs wakeup values with synchronous listener removal, managed by `GlobalProgressStreamSource`.
    struct Registration {
        let values: AsyncStream<Void>
        let cancel: () -> Void
    }

    /// Registration and removal wait for pending changes on the center's queue. Call from the main actor,
    /// never from a Darwin callback (which itself runs on the center's queue).
    @MainActor
    static func makeWakeupStream(center: DarwinNotificationCenter = .shared) -> Registration {
        let name = GlobalProgressXPCContract.becameActiveNotification
        return makeWakeupStream(
            addObserver: { token, receive in center.addObserver(token, for: name) { _ in receive() } },
            removeObserver: { token in center.removeObserver(token, for: name) },
            // isObserver synchronously drains the same serial queue used by add/remove.
            waitForPendingObserverChanges: { token in _ = center.isObserver(token, for: name) }
        )
    }

    @MainActor
    static func makeWakeupStream(
        addObserver: (NSObject, @escaping () -> Void) -> Void,
        removeObserver: @escaping (NSObject) -> Void,
        waitForPendingObserverChanges: @escaping (NSObject) -> Void
    ) -> Registration {
        let (values, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = NSObject() // the center holds observers weakly; cancellation owns this token
        addObserver(token) { continuation.yield(()) }
        waitForPendingObserverChanges(token)
        return Registration(values: values, cancel: {
            removeObserver(token)
            waitForPendingObserverChanges(token)
            continuation.finish()
        })
    }
}
