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
import ProtonCoreAuthentication
import ProtonCoreServices
import ProtonCoreNetworking
import ProtonCoreUtilities
import PDCore
import ProtonDriveSDK

public protocol MetadataUpdaterAwareHttpCallExecutor {
    /// Drive api calls (takes `/drive/...` path)
    func requestDriveApi(
        method: String,
        relativePath: String,
        content: Data,
        headers: [(String, [String])],
        metadataUpdater: MetadataUpdaterProtocol,
        retryConfiguration: HttpClientResilience.Configuration,
        rateLimitGate: RateLimitGate
    ) async -> Result<HttpClientResponse, Error>

    /// Raw request (takes whole url) - should be storage request
    func requestUploadToStorage(
        method: String,
        url: String,
        content: StreamForUpload,
        headers: [(String, [String])],
        retryConfiguration: HttpClientResilience.Configuration,
        rateLimitGate: RateLimitGate
    ) async -> Result<HttpClientResponse, Error>

    func requestSmallUpload(
        method: String,
        url: String,
        content: Data,
        metadata: Data,
        headers: [(String, [String])],
        metadataUpdater: MetadataUpdaterProtocol,
        rateLimitGate: RateLimitGate
    ) async -> Result<HttpClientResponse, Error>

    func requestDownloadFromStorage(
        method: String,
        url: String,
        content: Data,
        headers: [(String, [String])],
        retryConfiguration: HttpClientResilience.Configuration,
        rateLimitGate: RateLimitGate,
        downloadStreamCreator: @Sendable @escaping (URLSession.AsyncBytes) -> AnyAsyncSequence<UInt8>
    ) async -> Result<HttpClientStream, Error>
}

/// Family identifiers used by this layer when feeding the shared 429 gate.
/// Storage requests don't have semantic URL structure, so they get static keys
/// instead of the path-based `RateLimitFamily.from(method:path:)`.
enum StorageRateLimitFamily {
    static let upload = "storageUpload"
    static let download = "storageDownload"
}

func extractHeaders(fromAllHeaderFields allHeaderFields: [AnyHashable: Any]) -> [(String, [String])] {
    allHeaderFields.map { key, value in
        let extractedValues: [String]
        switch value {
        case let strings as [String]:
            extractedValues = strings
        case let values as [Any]:
            extractedValues = values.map(String.init(describing:))
        default:
            extractedValues = [String(describing: value)]
        }
        return (String(describing: key), extractedValues)
    }
}

// TODO(SDK): clean up force casts etc
extension PMAPIService: MetadataUpdaterAwareHttpCallExecutor {

    /// Make the Proton Core HTTP client conform to the SDK HTTP client protocol
    public func requestDriveApi(
        method: String,
        relativePath: String,
        content: Data,
        headers: [(String, [String])],
        metadataUpdater: MetadataUpdaterProtocol,
        retryConfiguration: HttpClientResilience.Configuration,
        rateLimitGate: RateLimitGate
    ) async -> Result<HttpClientResponse, Error> {
        Log.debug("sdk request (drive): \(relativePath), headers: \(headers), content: \(String(data: content, encoding: .utf8) ?? "\(content.count) bytes")", domain: .sdk)

        // Same `(method, path) → family` mapping PDClient endpoints use, so a 429
        // observed here also blocks PDClient calls for the same resource shape.
        let family = RateLimitFamily.from(method: method, path: relativePath)

        return await HttpClientResilience.performWithResilience(
            configuration: retryConfiguration,
            rateLimitGate: rateLimitGate,
            family: family,
            refreshCredentials: performRequestToRefreshCredentials()
        ) { [weak self] previousError in
            guard let self else {
                let error = (previousError ?? CocoaError(.userCancelled))
                return .doNotRetry(.failure(error))
            }
            let result = await self.executeDriveAPICall(
                method: method, path: relativePath, content: content, headers: headers, metadataUpdater: metadataUpdater
            )
            return .retryIfNeeded(result)
        }
    }

    public func requestUploadToStorage(
        method: String,
        url: String,
        content: StreamForUpload,
        headers: [(String, [String])],
        retryConfiguration: HttpClientResilience.Configuration,
        rateLimitGate: RateLimitGate
    ) async -> Result<HttpClientResponse, Error> {
        Log.debug("upload request: \(url), headers: \(headers)", domain: .sdk)

        let uploader = SDKURLSessionStreamingUploader()

        return await HttpClientResilience.performWithResilience(
            configuration: retryConfiguration,
            rateLimitGate: rateLimitGate,
            family: StorageRateLimitFamily.upload,
            refreshCredentials: performRequestToRefreshCredentials()
        ) { [weak self] previousError in
            guard let self else {
                let error = (previousError ?? CocoaError(.userCancelled))
                return .doNotRetry(.failure(error))
            }
            return await executeUpload(
                uploader: uploader,
                method: method,
                url: url,
                content: content,
                headers: headers,
                retryConfiguration: retryConfiguration,
                previousError: previousError
            )
        }
    }

    public func requestDownloadFromStorage(
        method: String,
        url: String,
        content: Data,
        headers: [(String, [String])],
        retryConfiguration: HttpClientResilience.Configuration,
        rateLimitGate: RateLimitGate,
        downloadStreamCreator: @Sendable @escaping (URLSession.AsyncBytes) -> AnyAsyncSequence<UInt8>
    ) async -> Result<HttpClientStream, Error> {
        Log.debug("download request: \(url), headers: \(headers), content: \(String(data: content, encoding: .utf8) ?? "\(content.count) bytes")", domain: .sdk)

        let downloader = SDKURLSessionStreamingDownloader(downloadStreamCreator: downloadStreamCreator)

        return await HttpClientResilience.performWithResilience(
            configuration: retryConfiguration,
            rateLimitGate: rateLimitGate,
            family: StorageRateLimitFamily.download,
            refreshCredentials: performRequestToRefreshCredentials()
        ) { [weak self] previousError in
            guard let self else {
                let error = (previousError ?? CocoaError(.userCancelled))
                return .doNotRetry(.failure(error))
            }

            let result = await executeDownload(
                downloader: downloader,
                method: method,
                url: url,
                content: content,
                headers: headers,
                retryConfiguration: retryConfiguration
            )
            return .retryIfNeeded(result)
        }
    }
    
    public func requestSmallUpload(
        method: String,
        url: String,
        content: Data,
        metadata: Data,
        headers: [(String, [String])],
        metadataUpdater: MetadataUpdaterProtocol,
        rateLimitGate: RateLimitGate
    ) async -> Result<HttpClientResponse, Error> {
        guard let parameters = try? JSONSerialization.jsonObject(with: metadata) as? JSONDictionary else {
            return .failure(CocoaError(.propertyListReadCorrupt))
        }
        // Both small-upload endpoints are non-idempotent POSTs. Do not allow URLSession
        // to infer that replay is safe from an idempotent HTTP method such as PUT.
        guard method == HTTPMethod.post.rawValue,
              let components = URLComponents(string: url),
              let originalURL = components.url else {
            return .failure(URLError(.unsupportedURL))
        }
        let family = RateLimitFamily.from(method: method, path: components.path)
        return await HttpClientResilience.performSmallUploadWithResilience(
            rateLimitGate: rateLimitGate,
            family: family,
            refreshCredentials: performRequestToRefreshCredentials()
        ) { [self] in
            do {
                let request = try await createSmallUploadRequest(
                    url: originalURL,
                    components: components,
                    method: method,
                    headers: headers
                )
                let (data, response) = try await sendSmallUpload(request: request, content: content)
                try await updateSmallUploadSession(response: response, request: request)
                return .success(try await handleSmallUploadResponse(
                    data: data,
                    response: response,
                    path: components.path,
                    parameters: parameters,
                    metadataUpdater: metadataUpdater
                ))
            } catch is CancellationError {
                return .failure(URLError(.cancelled))
            } catch {
                return .failure(error)
            }
        }
    }

    private func createSmallUploadRequest(
        url: URL,
        components: URLComponents,
        method: String,
        headers: [(String, [String])]
    ) async throws -> URLRequest {
        // TODO [@alecrim, DM-1066]: Share HTTP handling between regular Drive API calls and small uploads if possible
        try Task.checkCancellation()
        var request = await createAuthenticatedRequest(
            url: url.absoluteString,
            method: method,
            headers: headers
        )
        request.timeoutInterval = 60
        guard request.value(forHTTPHeaderField: HTTPHeaderName.authorization) != nil else {
            throw URLError(.userAuthenticationRequired)
        }
        guard var routedURL = URLComponents(string: dohInterface.getCurrentlyUsedHostUrl()) else {
            throw URLError(.badURL)
        }
        routedURL.percentEncodedPath += components.percentEncodedPath
        routedURL.percentEncodedQuery = components.percentEncodedQuery
        guard let requestURL = routedURL.url else { throw URLError(.badURL) }
        request.url = requestURL
        for (name, value) in dohInterface.getCurrentlyUsedUrlHeaders() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let token = dohInterface.getProxyToken() {
            request.setValue(token, forHTTPHeaderField: HTTPHeaderName.atlasSecret)
        }
        request.setValue("application/vnd.protonmail.v1+json", forHTTPHeaderField: HTTPHeaderName.accept)
        return request
    }

    private func sendSmallUpload(
        request: URLRequest,
        content: Data
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        try Task.checkCancellation()
        let (data, response) = try await DefaultURLSessionProvider.instance.session.upload(
            for: request,
            from: content,
            delegate: SmallUploadRedirectDelegate()
        )
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data: data, response: response)
    }

    private func updateSmallUploadSession(
        response: HTTPURLResponse,
        request: URLRequest
    ) async throws {
        // TODO [@alecrim, DM-1066]: Share HTTP handling between regular Drive API calls and small uploads if possible
        await dohInterface.synchronizeCookies(with: response, requestHeaders: request.allHTTPHeaderFields ?? [:])
        try Task.checkCancellation()
        if let date = response.value(forHTTPHeaderField: HTTPHeaderName.date), let time = DateParser.parse(time: date) {
            serviceDelegate?.onUpdate(serverTime: Int64(time.timeIntervalSince1970))
        }
    }

    func handleSmallUploadResponse(
        data: Data,
        response: HTTPURLResponse,
        path: String,
        parameters: JSONDictionary,
        metadataUpdater: MetadataUpdaterProtocol
    ) async throws -> HttpClientResponse {
        let result = HttpClientResponse(data: data, response: response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? JSONDictionary else {
            if (200..<300).contains(response.statusCode) {
                throw MetadataUpdateError.fieldMissing(missingField: "smallUpload.responseBody")
            }
            return result
        }
        // TODO [@alecrim, DM-1066]: Share HTTP handling between regular Drive API calls and small uploads if possible
        if json.code == APIErrorCode.humanVerificationRequired {
            // TODO [@alecrim, DM-1065]: improve human verification handling
            // Let the SDK surface the rejection; we cannot trigger the verification flow from this context.
            return result
        }
        if let code = json.code, code == APIErrorCode.badAppVersion || code == APIErrorCode.badApiVersion {
            await MainActor.run { forceUpgradeDelegate?.onForceUpgrade(message: json.errorMessage ?? "") }
        }
        if let code = json.code, code != APIErrorCode.responseOK {
            return result
        }
        try metadataUpdater.handleSmallUploadResponse(
            path: path,
            requestBody: parameters,
            responseStatusCode: response.statusCode,
            responseBody: json
        )
        return result
    }

    private func performRequestToRefreshCredentials() -> (Error) async throws -> Void {
        { [weak self] error in
            guard let self else { throw error }
            // We don't perform the refresh call directly, because there might be another refresh call racing against it.
            // So what we do instead, we perform a "dummy" request to kick off the synchronized refresh call.
            // User info request requires fresh credentials, so it will cause a synchronized refresh call to happen.
            // It's a workaround against the PMAPIService sychronized refresh mechanism being not public.
            let authenticator = Authenticator(api: self)
            _ = try await authenticator.getUserInfo()
        }
    }
    
    private func executeDriveAPICall(
        method: String,
        path: String,
        content: Data,
        headers requestHeaders: [(String, [String])],
        metadataUpdater: MetadataUpdaterProtocol
    ) async -> Result<HttpClientResponse, Error> {
        // Check if the task was cancelled before starting the request
        if Task.isCancelled {
            return .failure(URLError(.cancelled))
        }
        var dataTask: URLSessionDataTask?
        return await withTaskCancellationHandler {
            return await withCheckedContinuation { continuation in
                do {
                    let parameters: JSONDictionary?
                    if content.isEmpty {
                        parameters = nil
                    } else {
                        parameters = try JSONSerialization.jsonObject(with: content) as? JSONDictionary ?? nil
                    }
                    guard let method = HTTPMethod(rawValue: method) else {
                        assertionFailure("Unknown HTTP method type \(method)")
                        throw URLError(.unsupportedURL)
                    }
                    let headers = headersMap(requestHeaders)
                    self.request(
                        method: method,
                        path: path,
                        parameters: parameters,
                        headers: headers,
                        authenticated: true,
                        authRetry: true,
                        customAuthCredential: nil,
                        nonDefaultTimeout: 604_800,
                        // we opt-out from the PMAPIService retry policy because we have a custom resilience
                        retryPolicy: .userInitiated,
                        onDataTaskCreated: { dataTask = $0 },
                        jsonCompletion: { _, result in
                            do {
                                switch result {
                                case .success(let jsonDictionary):
                                    guard let httpResponse = dataTask?.response as? HTTPURLResponse else {
                                        throw URLError(.badServerResponse)
                                    }
                                    
                                    let response = try Self.handleDriveAPICallResponse(
                                        path: path,
                                        method: method,
                                        requestHeaders: requestHeaders,
                                        parameters: parameters,
                                        httpResponse: httpResponse,
                                        jsonDictionary: jsonDictionary,
                                        metadataUpdater: metadataUpdater
                                    )
                                    continuation.resume(returning: response)
                                    
                                case .failure(let error):
                                    guard let httpResponse = dataTask?.response as? HTTPURLResponse else {
                                        throw error
                                    }
                                    
                                    guard let jsonDictionary = error.userInfo[ResponseError.responseDictionaryUserInfoKey] as? JSONDictionary else {
                                        let response = HttpClientResponse(data: nil, response: httpResponse)
                                        continuation.resume(returning: .success(response))
                                        return
                                    }
                                    
                                    let response = try Self.handleDriveAPICallResponse(
                                        path: path,
                                        method: method,
                                        requestHeaders: requestHeaders,
                                        parameters: parameters,
                                        httpResponse: httpResponse,
                                        jsonDictionary: jsonDictionary,
                                        metadataUpdater: metadataUpdater
                                    )
                                    continuation.resume(returning: response)
                                }
                            } catch {
                                continuation.resume(returning: .failure(error))
                            }
                        })
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        } onCancel: {
            dataTask?.cancel()
        }
    }
    
    static private func handleDriveAPICallResponse(
        path: String,
        method: HTTPMethod,
        requestHeaders: [(String, [String])],
        parameters: JSONDictionary?,
        httpResponse: HTTPURLResponse,
        jsonDictionary: JSONDictionary,
        metadataUpdater: MetadataUpdaterProtocol
    ) throws -> Result<HttpClientResponse, Error> {
        let responseData = try JSONSerialization.data(withJSONObject: jsonDictionary, options: [])
        let response = HttpClientResponse(data: responseData, response: httpResponse)
        metadataUpdater.handleRequestAndResponse(
            path: path,
            method: method,
            requestHeaders: requestHeaders,
            requestBody: parameters,
            responseStatusCode: response.statusCode,
            responseHeaders: response.headers,
            responseBody: jsonDictionary
        )
        return .success(response)
    }
    
    private func executeUpload(
        uploader: SDKURLSessionStreamingUploader,
        method: String,
        url: String,
        content: StreamForUpload,
        headers: [(String, [String])],
        retryConfiguration: HttpClientResilience.Configuration,
        previousError: Error? = nil
    ) async -> ParticipateInRetries<HttpClientResponse> {
        // Check if the task was cancelled before starting the upload
        if Task.isCancelled {
            return .doNotRetry(.failure(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        }
        
        let request = await createAuthenticatedRequest(url: url, method: method, headers: headers)
        
        Log.debug("Uploading request: \(request)", domain: .sdk)
        
        // if the stream used for HTTP request body was already read from, we don't retry
        guard content.input.streamStatus == .notOpen else {
            Log.debug("HttpClientResilience: not retrying upload due to already written stream", domain: .networking)
            let error = (previousError ?? CocoaError(.userCancelled))
            return .retryIfNeeded(.failure(error))
        }

        do {
            let result = try await uploader.upload(
                streamedRequest: request,
                streamForUpload: content
            )
            return .retryIfNeeded(result)
        } catch {
            return .retryIfNeeded(.failure(error))
        }
    }
    
    private func executeDownload(
        downloader: SDKURLSessionStreamingDownloader,
        method: String,
        url: String,
        content: Data,
        headers: [(String, [String])],
        retryConfiguration: HttpClientResilience.Configuration
    ) async -> Result<HttpClientStream, Error> {
        // Check if the task was cancelled before starting the upload
        if Task.isCancelled {
            return .failure(URLError(.cancelled))
        }
        
        let request = await createAuthenticatedRequest(url: url, method: method, headers: headers)
        Log.debug("Downloading request: \(request)", domain: .sdk)
        return await downloader.download(request: request)
    }
    
    private func createAuthenticatedRequest(
        url: String,
        method: String,
        headers: [(String, [String])]
    ) async -> URLRequest {
        var updatedHeaders = headers
        
        if let serviceDelegate {
            updatedHeaders.append((HTTPHeaderName.appVersion, [serviceDelegate.appVersion]))
            updatedHeaders.append((HTTPHeaderName.locale, [serviceDelegate.locale]))
            if let userAgent = serviceDelegate.userAgent {
                updatedHeaders.append((HTTPHeaderName.userAgent, [userAgent]))
            }
            if let additionalHeaders = serviceDelegate.additionalHeaders {
                additionalHeaders.forEach { updatedHeaders.append(($0, [$1])) }
            }
        } else {
            assertionFailure("PMAPIService must have service delegate set")
        }
        
        updatedHeaders.append((HTTPHeaderName.sessionUID, [sessionUID]))
        switch await fetchAuthCredentials() {
        case .found(let credentials):
            updatedHeaders.append((HTTPHeaderName.authorization, ["Bearer \(credentials.accessToken)"]))
        case .notFound, .wrongConfigurationNoDelegate:
            if (authDelegate as? PMAPIClient)?.isSignedIn() == true {
                assertionFailure("The storage calls should always be performed with valid credentials")
            }
            break
        }
        
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 604_800
        request.httpMethod = method
        for header in updatedHeaders {
            var values = header.1
            guard !values.isEmpty else { continue }
            let firstValue = values.removeFirst()
            request.setValue(firstValue, forHTTPHeaderField: header.0)
            if !values.isEmpty {
                values.forEach { value in
                    request.addValue(value, forHTTPHeaderField: header.0)
                }
            }
        }
        return request
    }
    
    /// Extract response headers without going through Alamofire's HTTPHeaders (which does O(n²) dedup)
    static func extractHeaders(from response: HTTPURLResponse) -> [(String, [String])] {
        PDSDKCore.extractHeaders(fromAllHeaderFields: response.allHeaderFields)
    }

    /// Map headers from the array of tuples provided by the SDK to a dictionary required by Proton Core Networking
    private func headersMap(_ headers: [(String, [String])]) -> [String: Any] {
        var map: [String: Any] = [:]
        for (key, values) in headers {
            if values.count == 1 {
                map[key] = values[0]
            } else {
                map[key] = values
            }
        }
        return map
    }
}

// Retains the existing behavior to reject redirection on small file uploads.
private final class SmallUploadRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
