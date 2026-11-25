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
import TrustKit

struct FailedRequestRecordingSessionFactory: SessionFactoryInterface {
    private let factory: SessionFactoryInterface
    private let recorder: FailedRequestRecorder

    init(factory: SessionFactoryInterface, recorder: FailedRequestRecorder) {
        self.factory = factory
        self.recorder = recorder
    }

    func createSessionInstance(url apiHostUrl: String) -> Session {
        FailedRequestRecordingSession(session: factory.createSessionInstance(url: apiHostUrl), recorder: recorder)
    }

    func createSessionRequest(parameters: Any?, urlString: String, method: HTTPMethod, timeout: TimeInterval,
                              retryPolicy: ProtonRetryPolicy.RetryMode) throws -> SessionRequest {
        try factory.createSessionRequest(parameters: parameters, urlString: urlString, method: method, timeout: timeout,
                                         retryPolicy: retryPolicy)
    }
}

/// Forwards every call to the wrapped session and passes each result to the recorder.
/// Implements every requirement: the `Session` extension's default `generate` builds a request that
/// the wrapped session rejects.
final class FailedRequestRecordingSession: Session {
    private let session: Session
    private let recorder: FailedRequestRecorder

    init(session: Session, recorder: FailedRequestRecorder) {
        self.session = session
        self.recorder = recorder
    }

    var sessionConfiguration: URLSessionConfiguration {
        session.sessionConfiguration
    }

    func generate(with method: HTTPMethod, urlString: String, parameters: Any?, timeout: TimeInterval?,
                  retryPolicy: ProtonRetryPolicy.RetryMode) throws -> SessionRequest {
        try session.generate(with: method, urlString: urlString, parameters: parameters, timeout: timeout, retryPolicy: retryPolicy)
    }

    func request(with request: SessionRequest, onDataTaskCreated: @escaping (URLSessionDataTask) -> Void,
                 completion: @escaping JSONResponseCompletion) {
        session.request(with: request, onDataTaskCreated: onDataTaskCreated, completion: recording(request, completion))
    }

    func request<T>(with request: SessionRequest, jsonDecoder: JSONDecoder?, onDataTaskCreated: @escaping (URLSessionDataTask) -> Void,
                    completion: @escaping DecodableResponseCompletion<T>) where T: SessionDecodableResponse {
        session.request(with: request, jsonDecoder: jsonDecoder, onDataTaskCreated: onDataTaskCreated,
                        completion: recording(request, completion))
    }

    func download(with request: SessionRequest, destinationDirectoryURL: URL, completion: @escaping DownloadCompletion) {
        session.download(with: request, destinationDirectoryURL: destinationDirectoryURL) { [recorder] response, url, error in
            recorder.record(request, response: response, error: error)
            completion(response, url, error)
        }
    }

    // ProtonCore's `Session` protocol defines these signatures.
    // swiftlint:disable function_parameter_count
    func upload(with request: SessionRequest, keyPacket: Data, dataPacket: Data, signature: Data?,
                completion: @escaping JSONResponseCompletion, uploadProgress: ProgressCompletion?) {
        session.upload(with: request, keyPacket: keyPacket, dataPacket: dataPacket, signature: signature,
                       completion: recording(request, completion), uploadProgress: uploadProgress)
    }

    func upload<T>(with request: SessionRequest, keyPacket: Data, dataPacket: Data, signature: Data?, jsonDecoder: JSONDecoder?,
                   completion: @escaping DecodableResponseCompletion<T>, uploadProgress: ProgressCompletion?) where T: SessionDecodableResponse {
        session.upload(with: request, keyPacket: keyPacket, dataPacket: dataPacket, signature: signature, jsonDecoder: jsonDecoder,
                       completion: recording(request, completion), uploadProgress: uploadProgress)
    }

    func upload(with request: SessionRequest, files: [String: URL], completion: @escaping JSONResponseCompletion,
                uploadProgress: ProgressCompletion?) {
        session.upload(with: request, files: files, completion: recording(request, completion), uploadProgress: uploadProgress)
    }

    func upload<T>(with request: SessionRequest, files: [String: URL], jsonDecoder: JSONDecoder?,
                   completion: @escaping DecodableResponseCompletion<T>, uploadProgress: ProgressCompletion?) where T: SessionDecodableResponse {
        session.upload(with: request, files: files, jsonDecoder: jsonDecoder, completion: recording(request, completion),
                       uploadProgress: uploadProgress)
    }

    func uploadFromFile(with request: SessionRequest, keyPacket: Data, dataPacketSourceFileURL: URL, signature: Data?,
                        completion: @escaping JSONResponseCompletion, uploadProgress: ProgressCompletion?) {
        session.uploadFromFile(with: request, keyPacket: keyPacket, dataPacketSourceFileURL: dataPacketSourceFileURL,
                               signature: signature, completion: recording(request, completion), uploadProgress: uploadProgress)
    }

    func uploadFromFile<T>(with request: SessionRequest, keyPacket: Data, dataPacketSourceFileURL: URL, signature: Data?,
                           jsonDecoder: JSONDecoder?, completion: @escaping DecodableResponseCompletion<T>,
                           uploadProgress: ProgressCompletion?) where T: SessionDecodableResponse {
        session.uploadFromFile(with: request, keyPacket: keyPacket, dataPacketSourceFileURL: dataPacketSourceFileURL,
                               signature: signature, jsonDecoder: jsonDecoder, completion: recording(request, completion),
                               uploadProgress: uploadProgress)
    }
    // swiftlint:enable function_parameter_count

    func setChallenge(noTrustKit: Bool, trustKit: TrustKit?) {
        session.setChallenge(noTrustKit: noTrustKit, trustKit: trustKit)
    }

    func failsTLS(request: SessionRequest) -> String? {
        session.failsTLS(request: request)
    }

    private func recording<T>(
        _ request: SessionRequest, _ completion: @escaping (URLSessionDataTask?, Result<T, SessionResponseError>) -> Void
    ) -> (URLSessionDataTask?, Result<T, SessionResponseError>) -> Void {
        { [recorder] task, result in
            recorder.record(request, task: task, result: result)
            completion(task, result)
        }
    }
}
#endif
