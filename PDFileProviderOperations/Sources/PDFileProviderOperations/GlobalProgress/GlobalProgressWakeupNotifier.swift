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
import PDCore
import PDFileProvider

/// Lets `GlobalProgressXPCServiceSource` signal activity to an app waiting to reconnect.
protocol GlobalProgressWakeupNotifier {
    func postWakeup()
}

/// Posts the activity notification consumed by the app's `GlobalProgressWakeupStream`.
struct DarwinGlobalProgressWakeupNotifier: GlobalProgressWakeupNotifier {
    let notificationCenter: DarwinNotificationCenter

    func postWakeup() {
        notificationCenter.postNotification(
            GlobalProgressXPCContract.becameActiveNotification
        )
    }
}
