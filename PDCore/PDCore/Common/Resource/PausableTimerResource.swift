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

import Combine
import Foundation

public protocol PausableTimerResource {
    var updatePublisher: AnyPublisher<Void, Never> { get }
    func resume()
    func pause()
    func stop()
    func getElapsedTime() -> TimeInterval
}

public final class CommonRunLoopPausableTimerResource: PausableTimerResource {
    private var timer: Timer?
    private var subject = PassthroughSubject<Void, Never>()
    private let duration: TimeInterval
    private var startTime: Double?
    // Cumulative time since an interval start. It resets after interval finishes or if the timer is stopped.
    // E.g. - start timer {event1}, pause {event2}, resume {event3}, stop {event4}
    // - the result should be sum of intervals {event1} - {event2} and {event3} - {event4}
    private var elapsedTime: Double = 0

    public var updatePublisher: AnyPublisher<Void, Never> {
        subject.eraseToAnyPublisher()
    }

    /// `duration`: in seconds
    public init(duration: TimeInterval) {
        self.duration = duration
    }

    public func resume() {
        guard timer == nil else {
            return
        }

        startTime = Date.timeIntervalSinceReferenceDate
        let interval = max(duration - elapsedTime, 0)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleIntervalEnd()
        }
        self.timer = timer
        RunLoop.current.add(timer, forMode: .common)
    }

    public func pause() {
        guard timer != nil else {
            return
        }

        elapsedTime += Date.timeIntervalSinceReferenceDate - (startTime ?? 0.0)
        timer?.invalidate()
        timer = nil
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        elapsedTime = 0
    }

    public func getElapsedTime() -> TimeInterval {
        if timer != nil {
            return elapsedTime + Date.timeIntervalSinceReferenceDate - (startTime ?? 0.0)
        } else {
            return elapsedTime
        }
    }

    private func handleIntervalEnd() {
        timer = nil
        elapsedTime += Date.timeIntervalSinceReferenceDate - (startTime ?? 0.0)
        subject.send()
        elapsedTime = 0
        resume()
    }
}
