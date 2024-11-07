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
import PDCore

final class MemoryWarningObserver {
    private let memoryPressureDispatchSource: DispatchSourceMemoryPressure
    private let memoryDiagnosticResource: MemoryDiagnosticsResource

    init(memoryDiagnosticResource: MemoryDiagnosticsResource) {
        self.memoryDiagnosticResource = memoryDiagnosticResource
        self.memoryPressureDispatchSource = DispatchSource.makeMemoryPressureSource(eventMask: .critical)
        setUpMemoryPressureDispatchSource()
    }

    private func setUpMemoryPressureDispatchSource() {
        let handler: DispatchSourceProtocol.DispatchSourceHandler = { [weak self] in
            guard let self, !self.memoryPressureDispatchSource.isCancelled else { return }
            let event = self.memoryPressureDispatchSource.data
            guard event == .critical else { return }

            reportCriticalMemory()
        }

        memoryPressureDispatchSource.setEventHandler(handler: handler)
        memoryPressureDispatchSource.setRegistrationHandler(handler: handler)

        memoryPressureDispatchSource.activate()
    }

    private func reportCriticalMemory() {
        guard let diagnostics = try? memoryDiagnosticResource.getDiagnostics() else {
            return
        }

        // TODO: Add metrics

        let sendToSentry = diagnostics.usedMB > 1_000 // only send to Sentry if the app's memory consumption is exceptionally high
        Log.info("🐏 Critical memory warning observed. Proton Drive app memory use: \(diagnostics.usedMB) MB", domain: .application, sendToSentryIfPossible: sendToSentry)
    }
}
