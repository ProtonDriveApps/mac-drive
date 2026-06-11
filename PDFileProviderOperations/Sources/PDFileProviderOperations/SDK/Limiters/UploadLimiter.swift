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

public protocol UploadLimiter: Sendable {
    func runOperation<T>(_ operation: () async throws -> T) async throws -> T
}

public struct UploadLimiterPipeline: UploadLimiter {
    private let limiters: [any UploadLimiter]

    public init(_ limiters: [any UploadLimiter]) {
        self.limiters = limiters
    }

    public func runOperation<T>(_ operation: () async throws -> T) async throws -> T {
        try await run(at: 0, operation)
    }

    private func run<T>(at index: Int, _ operation: () async throws -> T) async throws -> T {
        guard index < limiters.count else { return try await operation() }
        return try await limiters[index].runOperation {
            try await self.run(at: index + 1, operation)
        }
    }
}
