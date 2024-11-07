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

import AppKit
import PDCore
import PDLocalization

final class UserMessageHandler: UserMessageHandlerProtocol {
    func handleError(_ error: any LocalizedError) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = error.localizedDescription
            alert.addButton(withTitle: Localization.general_dismiss)
            let action = { [alert] in alert.window.close() }
            
            if alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn {
                action()
            }
        }
    }

    func handleSuccess(_ message: String) {
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: Localization.general_ok)
            let action = { [alert] in alert.window.close() }

            if alert.runModal() == NSApplication.ModalResponse.alertFirstButtonReturn {
                action()
            }
        }
    }
}
