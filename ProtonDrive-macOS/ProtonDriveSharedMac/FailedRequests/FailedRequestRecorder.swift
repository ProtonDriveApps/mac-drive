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
import Foundation
import ProtonCoreNetworking

/// Records requests that end with an HTTP status outside 200–299 or with a transport error other than
/// cancellation. Never records headers, bodies or query strings.
struct FailedRequestRecorder {
    static let errorLimit = 500
    /// Longest path `build_defs/failed_requests.py` accepts.
    static let pathLimit = 300

    private let context: FailedRequestContextResource
    private let resource: FailedRequestLogResource

    init(context: FailedRequestContextResource, resource: FailedRequestLogResource) {
        self.context = context
        self.resource = resource
    }

    func record<T>(_ request: SessionRequest, task: URLSessionDataTask?, result: Result<T, SessionResponseError>) {
        switch result {
        case .success(let value):
            // ProtonCore passes JSON error bodies of non-2xx responses as success.
            record(request.request, response: task?.response, body: value as? JSONDictionary, failure: nil)
        case .failure(.responseBodyIsNotAJSONDictionary(let body, let response)),
             .failure(.responseBodyIsNotADecodableObject(let body, let response)):
            record(request.request, response: response ?? task?.response, body: body.flatMap(Self.dictionary), failure: nil)
        case .failure(.networkingEngineError(let error)):
            record(request.request, response: task?.response, body: nil, failure: error)
        case .failure(.configurationError):
            break
        }
    }

    func record(_ request: SessionRequest, response: URLResponse?, error: NSError?) {
        record(request.request, response: response, body: nil, failure: error)
    }

    /// For requests sent without a ProtonCore session.
    func record(_ request: URLRequest, response: URLResponse?, body: Data?, error: NSError?) {
        record(request, response: response, body: body.flatMap(Self.dictionary), failure: error)
    }

    private func record(_ request: URLRequest?, response: URLResponse?, body: JSONDictionary?, failure: NSError?) {
        guard let testCase = context.testCase,
              let url = request?.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else {
            return
        }
        let method = request?.httpMethod ?? "GET"
        let path = components.percentEncodedPath.isEmpty ? "/" : String(components.percentEncodedPath.prefix(Self.pathLimit))

        if let status = (response as? HTTPURLResponse)?.statusCode {
            guard !(200..<300).contains(status) else { return }
            resource.write(FailedRequestRecord(process: context.process, testCase: testCase, method: method, host: host, path: path,
                                               status: status, code: body?["Code"] as? Int, error: Self.cut(body?["Error"] as? String),
                                               domain: nil, errorCode: nil))
        } else if let failure, !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) {
            // Descriptions of other domains, such as Alamofire's, can contain the URL with its query string.
            let description = failure.domain == NSURLErrorDomain ? failure.localizedDescription : nil
            resource.write(FailedRequestRecord(process: context.process, testCase: testCase, method: method, host: host, path: path,
                                               status: nil, code: nil, error: Self.cut(description),
                                               domain: failure.domain, errorCode: failure.code))
        }
    }

    private static func dictionary(_ body: Data) -> JSONDictionary? {
        (try? JSONSerialization.jsonObject(with: body)) as? JSONDictionary
    }

    private static func cut(_ text: String?) -> String? {
        text.map { String($0.prefix(errorLimit)) }
    }
}
#endif
