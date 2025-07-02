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
import ProtonDriveSdk

public protocol ObservabilityServiceProtocol {
    var handle: Int { get }

    func flush(cancellationTokenSource: CancellationTokenSource) async throws
}

public final class ObservabilityService: ObservabilityServiceProtocol {

    public private(set) var handle: ObjectHandle = 0

    public init?(session: ProtonApiSessionProtocol) {
        let result = observability_service_start_new(session.handle, &handle)
        guard Status(result: result) == .ok else {
            return nil
        }
    }

    public func flush(cancellationTokenSource: CancellationTokenSource) async throws {
        return try await invokeDDKWithoutRequest(
            objectHandle: handle,
            cancellationTokenSource: cancellationTokenSource,
            functionInvocation: observability_service_flush
        ) { tcsPtr, _ in
            tcsPtr?.unretainedTaskCompletion(with: Void.self)
                   .setResult(value: ())
        }
    }

    deinit {
        observability_service_free(handle)
    }
}
