// Copyright (c) 2023 Proton AG
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

class ProcessObserver {
    public static let timeInterval: TimeInterval = 2
    private var timer: Timer?

    @MainActor
    public func startTimer(
        interval: TimeInterval = ProcessObserver.timeInterval,
        onTick block: @Sendable @escaping (FileProviderStatus) -> Void
    ) {
        stopTimer()

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            block(FileProviderStatus(processes: Self.runningProcesses))
        }
        self.timer = timer
    }

    static var runningProcesses: [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-ax"]

        let pipe = Pipe()
        task.standardOutput = pipe

        var output = [String]()

        do {
            try task.run()
            while task.isRunning {
                let data = pipe.fileHandleForReading.availableData
                if let string = String(data: data, encoding: .utf8), !string.isEmpty {
                    output.append(string)
                }
            }
            task.waitUntilExit()

            let all = output.joined()
            let split = all.split(separator: "\n").map { "\($0)" }
            return split
        } catch {
            return []
        }
    }

    public func stopTimer() {
        timer?.invalidate()
    }

    deinit {
        stopTimer()
    }
}
