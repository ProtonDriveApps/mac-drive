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

#if DEBUG
import Combine
import Foundation

public extension DarwinNotification.Name {
    static let simulateNetworkOffline = DarwinNotification.Name("ch.protonmail.drive.debug.network.offline")
    static let simulateNetworkOnline = DarwinNotification.Name("ch.protonmail.drive.debug.network.online")
}

/// Passes through to the wrapped resource until a state is simulated.
public final class DebugConnectionStateResource: ConnectionStateResource {
    private let wrapped: ConnectionStateResource
    private let simulatedState = CurrentValueSubject<NetworkState?, Never>(nil)

    public init(wrapping wrapped: ConnectionStateResource) {
        self.wrapped = wrapped
    }

    public var currentState: NetworkState {
        simulatedState.value ?? wrapped.currentState
    }

    public var isConfirmedReachable: Bool {
        get async {
            if let simulated = simulatedState.value { return simulated.isReachable }
            return await wrapped.isConfirmedReachable
        }
    }

    public var state: AnyPublisher<NetworkState, Never> {
        simulatedState
            .combineLatest(wrapped.state.prepend(wrapped.currentState))
            .map { simulated, real in simulated ?? real }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    public func startMonitoring() {
        wrapped.startMonitoring()
    }

    public func cancel() {
        wrapped.cancel()
    }

    /// - Parameter state: the state to simulate, or `nil` to fall back to the real one.
    public func setSimulatedState(_ state: NetworkState?) {
        simulatedState.send(state)
    }

    /// Observes the QA toggle and the UI test commands.
    public func startObservingSimulationCommands(notificationCenter: DarwinNotificationCenter = .shared) {
        if DebugConstants.commandLineContains(flags: [.uiTests, .simulateOffline]) {
            setSimulatedState(.unreachable)
        } else if DebugConstants.commandLineContains(flags: [.uiTests, .simulateUnreachableAPIWithReachableConnectivity]) {
            setSimulatedState(.reachable(.wifi))
        }

        observe(.simulateNetworkOffline, on: notificationCenter, logging: "going offline") {
            $0.setSimulatedState(.unreachable)
        }
        observe(.simulateNetworkOnline, on: notificationCenter, logging: "going online") {
            $0.setSimulatedState(nil)
        }
    }

    private func observe(
        _ name: DarwinNotification.Name,
        on notificationCenter: DarwinNotificationCenter,
        logging message: String,
        apply: @escaping (DebugConnectionStateResource) -> Void
    ) {
        notificationCenter.addObserver(self, for: name) { [weak self] _ in
            DispatchQueue.main.async {
                Log.info("Network simulation: \(message)", domain: .networking)
                if let self {
                    apply(self)
                }
            }
        }
    }
}
#endif
