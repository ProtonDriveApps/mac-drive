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
import PDClient
import PDCore

class ActivityService {
    private let frequency: TimeInterval
    private let tolerenceFactor = 0.2
    private let repository: ActivityRepository
    private var timer: Timer?

    init(repository: ActivityRepository, frequency: TimeInterval) {
        self.repository = repository
        self.frequency = frequency

        pingActive()

        let timer = Timer(timeInterval: frequency, repeats: true) { [weak self] _ in
            self?.pingActive()
        }
        self.timer = timer
        timer.tolerance = frequency * tolerenceFactor
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        timer?.invalidate()
    }

    private func pingActive() {
        Task {
            do {
                try await repository.pingActive()
                Log.info("Pinged active", domain: .diagnostics)
            } catch {
                Log.info("Failed to ping active", domain: .diagnostics)
            }
        }
    }
}
