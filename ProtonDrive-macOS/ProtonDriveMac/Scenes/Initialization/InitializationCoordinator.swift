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

import SwiftUI
import ProtonCoreUtilities

public struct InitializationProgress {
    
    public static let defaultMessage = "This may take a few minutes"
    
    let message: String
    let currentValue: Int
    let totalValue: Int
    
    public init(message: String = defaultMessage,
                currentValue: Int = 0,
                totalValue: Int = 0) {
        self.message = message
        self.currentValue = currentValue
        self.totalValue = totalValue
    }
}

public struct InitializationFailure {
    
    let error: Error
    let retry: () -> Void
    
    public init(error: Error, retry: @escaping () -> Void) {
        self.error = error
        self.retry = retry
    }
}

final class InitializationCoordinator: ObservableObject {
    
    @Published var initializationViewState: Either<InitializationProgress, InitializationFailure> = .left(.init())

    private weak var window: NSWindow?
    
    init(window: NSWindow) {
        self.window = window
    }
    
    func start() {
        window?.standardWindowButton(NSWindow.ButtonType.closeButton)?.isEnabled = false
        window?.contentView = NSHostingView(rootView: InitializationView(coordinator: self))
        window?.setAccessibilityIdentifier("InitializationCoordinator.window")
    }
    
    func update(progress: InitializationProgress) {
        Task { @MainActor in
            initializationViewState = .left(progress)
        }
    }
    
    func showFailure(error: Error, retry: @escaping () async throws -> Void) {
        Task { @MainActor in
            initializationViewState = .right(InitializationFailure(error: error, retry: {
                Task { [weak self] in
                    do {
                        try await retry()
                    } catch {
                        self?.showFailure(error: error, retry: retry)
                    }
                }
            }))
        }
    }
}
