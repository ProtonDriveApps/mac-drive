// Copyright (c) 2025 Proton AG
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
import ProtonDriveSDK
import ProtonCoreNetworking
import ProtonCoreServices

// The generic retry engine (`HttpClientResilience`, `Configuration`, `ParticipateInRetries`,
// `PerformRetryDecision`) lives in PDCore so both the SDK HTTP path and PDCore's metadata scan can share it.
// This file keeps the SDK-only surface: the `HttpClientResponse`/`HttpClientStream`-typed entry points and the
// HTTP-status-code classification, layered on top of PDCore's `performRateLimitedWithResilience`.

public enum HttpResilienceRequestType {
    case regularApi
    case storageDownload
    case storageUpload
}

public protocol HttpResilienceConfigurationProvider: Sendable {
    func retryConfiguration(for requestType: HttpResilienceRequestType) -> HttpClientResilience.Configuration
}

public enum DefaultHttpResilienceConfigurationProvider: HttpResilienceConfigurationProvider {
    case instance

    public func retryConfiguration(for requestType: HttpResilienceRequestType) -> HttpClientResilience.Configuration {
        switch requestType {
        case .regularApi: return .forDriveAPICalls
        case .storageUpload, .storageDownload: return .forNonRetriableStorageCalls
        }
    }
}

extension HttpClientResilience {

    /// Small uploads may retry rate-limit rejections, but never ambiguous transport or server failures.
    /// One credential refresh is allowed independently of the rate-limit retry budget.
    static func performSmallUploadWithResilience(
        rateLimitGate: RateLimitGate,
        family: String,
        refreshCredentials: @escaping (Error) async throws -> Void,
        operation: @escaping () async -> Result<HttpClientResponse, Error>
    ) async -> Result<HttpClientResponse, Error> {
        var didRefreshCredentials = false
        let result = await performRateLimitedWithResilience(
            configuration: .forDriveAPICalls,
            rateLimitGate: rateLimitGate,
            family: family,
            refreshCredentials: { _ in },
            operation: { _ in
                let result = await operation()
                guard case .success(let response) = result,
                      response.statusCode == 401, !didRefreshCredentials else {
                    return .retryIfNeeded(result)
                }
                // Handle refresh here so it neither consumes a 429 attempt nor hides refresh failures.
                do {
                    try Task.checkCancellation()
                    try await refreshCredentials(URLError(.userAuthenticationRequired))
                    didRefreshCredentials = true
                    await rateLimitGate.waitIfNeeded(family: family)
                    try Task.checkCancellation()
                    return .retryIfNeeded(await operation())
                } catch is CancellationError {
                    return .doNotRetry(.failure(URLError(.cancelled)))
                } catch {
                    return .doNotRetry(.failure(error))
                }
            }
        ) { result, attemptCount, configuration in
            guard case .success(let response) = result, response.statusCode == 429 else {
                return .noRetry(result)
            }
            await rateLimitGate.recordRateLimited(responseHeaders: response.headers, family: family)
            guard attemptCount < configuration.maxNumberOfTries else {
                return .noRetry(result)
            }
            return .retryAfter(.zero, previousError: nil)
        }
        // `.success` means an HTTP response was received, including something like a 429 rejection.
        // The retry driver returns that response if its retry sleep is cancelled.
        // Report cancellation in that case while preserving completed upload responses.
        if Task.isCancelled, case .success(let response) = result, response.statusCode == 429 {
            return .failure(URLError(.cancelled))
        }
        return result
    }

    public static func performWithResilience(
        configuration: Configuration,
        rateLimitGate: RateLimitGate,
        family: String,
        refreshCredentials: @escaping (Error) async throws -> Void,
        operation: @escaping (Error?) async -> ParticipateInRetries<HttpClientResponse>
    ) async -> Result<HttpClientResponse, Error> {
        await performRateLimitedWithResilience(
            configuration: configuration,
            rateLimitGate: rateLimitGate,
            family: family,
            refreshCredentials: refreshCredentials,
            operation: operation
        ) { result, retryCount, configuration in
            switch result {
            case .success(let response):
                return await parse(
                    response: response, retryCount: retryCount, configuration: configuration,
                    rateLimitGate: rateLimitGate, family: family
                )
            case .failure(let error):
                return parse(error: error, retryCount: retryCount, configuration: configuration)
            }
        }
    }

    static func performWithResilience(
        configuration: Configuration,
        rateLimitGate: RateLimitGate,
        family: String,
        refreshCredentials: @escaping (Error) async throws -> Void,
        operation: @escaping (Error?) async -> ParticipateInRetries<HttpClientStream>
    ) async -> Result<HttpClientStream, Error> {
        await performRateLimitedWithResilience(
            configuration: configuration,
            rateLimitGate: rateLimitGate,
            family: family,
            refreshCredentials: refreshCredentials,
            operation: operation
        ) { result, retryCount, configuration in
            switch result {
            case .success(let stream):
                return await parse(
                    stream: stream, retryCount: retryCount, configuration: configuration,
                    rateLimitGate: rateLimitGate, family: family
                )
            case .failure(let error):
                return parse(error: error, retryCount: retryCount, configuration: configuration)
            }
        }
    }

    static func parse(
        response: HttpClientResponse,
        retryCount: Int,
        configuration: Configuration,
        rateLimitGate: RateLimitGate,
        family: String
    ) async -> PerformRetryDecision<HttpClientResponse> {
        if let retryDecision = await commonRetryDecisionLogic(
            response, statusCode: response.statusCode, headers: response.headers,
            retryCount: retryCount, configuration: configuration,
            rateLimitGate: rateLimitGate, family: family
        ) {
            return retryDecision
        }

        Log.debug("HttpClientResilience no-200 response but no retry: \(response.statusCode)",
                  domain: .networking)

        return .noRetry(.success(response))
    }

    static func parse(
        stream: HttpClientStream,
        retryCount: Int,
        configuration: Configuration,
        rateLimitGate: RateLimitGate,
        family: String
    ) async -> PerformRetryDecision<HttpClientStream> {
        if let retryDecision = await commonRetryDecisionLogic(
            stream, statusCode: stream.statusCode, headers: stream.headers,
            retryCount: retryCount, configuration: configuration,
            rateLimitGate: rateLimitGate, family: family
        ) {
            return retryDecision
        }

        Log.debug("HttpClientResilience no-200 response but no retry: \(stream.statusCode)",
                  domain: .networking)

        return .noRetry(.success(stream))
    }

    static func parse<T>(
        error: Error, retryCount: Int, configuration: Configuration
    ) -> PerformRetryDecision<T> {
        guard retryCount < configuration.maxNumberOfTries else {
            return .noRetry(.failure(error))
        }

        let errorCodesIndicatingTimeoutOrNetworkError: Set<URLError.Code> = [
            .unknown,
            .badURL,
            .timedOut,
            .unsupportedURL,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .httpTooManyRedirects,
            .resourceUnavailable,
            .notConnectedToInternet,
            .redirectToNonExistentLocation,
            .badServerResponse,
            .userCancelledAuthentication,
            .userAuthenticationRequired,
            .zeroByteResource,
            .cannotDecodeRawData,
            .cannotDecodeContentData,
            .cannotParseResponse,
            .appTransportSecurityRequiresSecureConnection,
            .secureConnectionFailed,
            .serverCertificateHasBadDate,
            .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid,
            .clientCertificateRejected,
            .clientCertificateRequired,
            .cannotLoadFromNetwork,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
            .requestBodyStreamExhausted
        ]

        if let error = error as? URLError, errorCodesIndicatingTimeoutOrNetworkError.contains(error.code) {
            let duration = durationWithJitter(retryCount: retryCount, configuration: configuration)
            return .retryAfter(duration, previousError: error)
        }

        if let error = error as? ResponseError,
            error.isApiIsBlockedError || error.underlyingError?.code == APIErrorCode.potentiallyBlocked {
            let duration = durationWithJitter(retryCount: retryCount, configuration: configuration)
            return .retryAfter(duration, previousError: error)
        }

        if (error as NSError).code == APIErrorCode.potentiallyBlocked {
            let duration = durationWithJitter(retryCount: retryCount, configuration: configuration)
            return .retryAfter(duration, previousError: error)
        }

        Log.debug("HttpClientResilience error received but no retry: \(error.localizedDescription)",
                  domain: .networking)

        return .noRetry(.failure(error))
    }

    static func commonRetryDecisionLogic<T>(
        _ t: T,
        statusCode: Int,
        headers: [(String, [String])],
        retryCount: Int,
        configuration: Configuration,
        rateLimitGate: RateLimitGate,
        family: String,
        now: Date = Date()
    ) async -> PerformRetryDecision<T>? {
        guard retryCount <= configuration.maxNumberOfTries else {
            return .noRetry(.success(t))
        }

        // success!
        if (200...299).contains(statusCode) {
            return .noRetry(.success(t))
        }

        // retry on auth error if the configuration allows
        if configuration.retryOn401,
           statusCode == 401 {
            let previousError = ResponseError(httpCode: 401, responseCode: nil, userFacingMessage: "User logged out", underlyingError: nil)
            return .retryAfterRefreshingCredentials(previousError)
        }

        // 429: feed the shared gate (cross-tier with PDClient) and let the gate
        // do the actual wait at the next iteration's `waitIfNeeded`. We return
        // `.retryAfter(.zero, ...)` so the recursive helper schedules another
        // attempt without adding its own sleep on top of the gate's.
        if statusCode == 429 {
            await rateLimitGate.recordRateLimited(responseHeaders: headers, family: family, now: now)
            let previousError = ResponseError(
                httpCode: 429, responseCode: nil, userFacingMessage: "Too many requests", underlyingError: nil
            )
            return .retryAfter(.zero, previousError: previousError)
        }

        // retry based on exponential backoff
        if (500...599).contains(statusCode) {
            let previousError = ResponseError(httpCode: statusCode, responseCode: nil, userFacingMessage: "Internal server error", underlyingError: nil)
            let duration = durationWithJitter(retryCount: retryCount, configuration: configuration)
            return .retryAfter(duration, previousError: previousError)
        }

        return nil
    }

    // TODO: circuit breaker
}

extension RateLimitGate {
    /// Record the server's delay independently of whether this request may be retried.
    func recordRateLimited(
        responseHeaders: [(String, [String])],
        family: String,
        now: Date = Date()
    ) {
        let retryAfter = responseHeaders.first { name, _ in
            name.caseInsensitiveCompare(HTTPHeaderName.retryAfter) == .orderedSame
        }?.1.first.flatMap { Self.parseRetryAfterValue($0, now: now) }
        recordRateLimited(retryAfter: retryAfter, family: family, source: family)
    }
}
