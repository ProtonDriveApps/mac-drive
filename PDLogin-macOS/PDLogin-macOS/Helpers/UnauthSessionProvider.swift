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
import ProtonCoreNetworking
import ProtonCoreServices

public enum UnauthSessionOutcome: Equatable {
    case fetched
    case alreadyPresent
    /// The backend answered with an error, e.g. human verification or the endpoint is disabled.
    case unavailable
    case unreachable(errorDomain: String, errorCode: Int)
}

public typealias UnauthSessionOutcomeCallback = (UnauthSessionOutcome) -> Void

final class UnauthSessionProvider {
    private let api: APIService
    private let onOutcome: UnauthSessionOutcomeCallback

    init(api: APIService, onOutcome: @escaping UnauthSessionOutcomeCallback) {
        self.api = api
        self.onOutcome = onOutcome
    }

    /// Login continues when this fails: a 401 from the backend makes ProtonCore fetch the session and retry.
    func acquire() async {
        let result = await api.acquireSessionIfNeeded()
        onOutcome(Self.outcome(of: result))
    }

    private static func outcome(of result: Result<SessionAcquiringResult, NSError>) -> UnauthSessionOutcome {
        switch result {
        case .success(.sessionFetchedAndAvailable):
            return .fetched
        case .success(.sessionAlreadyPresent):
            return .alreadyPresent
        case .success(.sessionUnavailableAndNotFetched):
            return .unavailable
        case .failure(let error) where error.httpCode != nil:
            // ProtonCore takes the HTTP status from the URLSessionTask, which Alamofire hands over on the main queue.
            // While the main thread is busy, ProtonCore has no task yet and reports a backend error response as a failure.
            return .unavailable
        case .failure(let error):
            return .unreachable(errorDomain: error.domain, errorCode: error.code)
        }
    }
}
