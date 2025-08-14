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
import ProtonDriveProtos

public final class ProtonDriveClient {

    let handle: ObjectHandle

    public let observabilityService: ObservabilityServiceProtocol?

    public private(set) weak var session: ProtonApiSessionProtocol?

    public init?(session: ProtonApiSessionProtocol,
                 observability: ObservabilityServiceProtocol?,
                 clientCreationRequest: ProtonDriveClientCreateRequest) {
        self.session = session
        let observabilityHandle = observability?.handle ?? 0
        var handle = 0
        let result = try? safeAccess(clientCreationRequest) {
            drive_client_create(session.handle, observabilityHandle, $0, &handle)
        }.asStatus
        guard result == .ok else {
            return nil
        }
        self.handle = handle
        self.observabilityService = observability
    }

    deinit {
        drive_client_free(self.handle)
    }
}

// MARK: - Uploads

extension ProtonDriveClient {

    public func uploadFile(fileUploaderCreationRequest: FileUploaderCreationRequest,
                           fileUploadRequest: FileUploadRequest,
                           cancellationTokenSource: CancellationTokenSource,
                           onProgressUpdate: @escaping BytesProgressCallback) async throws -> FileUploadResponse {

        let uploader = try await FileUploader(protonDriveClient: self,
                                              fileUploaderCreationRequest: fileUploaderCreationRequest,
                                              cancellationTokenSource: cancellationTokenSource)
        return try await uploader.uploadFile(fileUploadRequest: fileUploadRequest,
                                             cancellationTokenSource: cancellationTokenSource,
                                             onProgressUpdate: onProgressUpdate)
    }

    public func uploadRevision(fileUploaderCreationRequest: FileUploaderCreationRequest,
                               revisionUploadRequest: RevisionUploadRequest,
                               cancellationTokenSource: CancellationTokenSource,
                               onProgressUpdate: @escaping BytesProgressCallback) async throws -> Revision {

        let uploader = try await FileUploader(protonDriveClient: self,
                                              fileUploaderCreationRequest: fileUploaderCreationRequest,
                                              cancellationTokenSource: cancellationTokenSource)
        return try await uploader.uploadRevision(revisionUploadRequest: revisionUploadRequest,
                                                 cancellationTokenSource: cancellationTokenSource,
                                                 onProgressUpdate: onProgressUpdate)
    }
}

// MARK: - Downloads

extension ProtonDriveClient {

    public func downloadFile(fileDownloadRequest: FileDownloadRequest,
                             cancellationTokenSource: CancellationTokenSource,
                             onProgressUpdate: @escaping BytesProgressCallback) async throws -> VerificationStatus {

        let downloader = try await FileDownloader(protonDriveClient: self,
                                                  cancellationTokenSource: cancellationTokenSource)
        return try await downloader.downloadFile(fileDownloadRequest: fileDownloadRequest,
                                                 cancellationTokenSource: cancellationTokenSource,
                                                 onProgressUpdate: onProgressUpdate)
    }
}

// MARK: - Register keys

extension ProtonDriveClient {

    public func registerShareKey(shareKeyRegistrationRequest: ShareKeyRegistrationRequest) -> Status {
        let result = try? safeAccess(shareKeyRegistrationRequest) {
            drive_client_register_share_key(handle, $0)
        }
        return Status(result: result)
    }

    public func registerNodeKeys(nodeKeysRegistrationRequest: NodeKeysRegistrationRequest) -> Status {
        let result = try? safeAccess(nodeKeysRegistrationRequest) {
            drive_client_register_node_keys(handle, $0)
        }
        return Status(result: result)
    }
}

// MARK: - Decrypt name

extension ProtonDriveClient {

    public func decryptNodeName(nodeNameDecryptionRequest: NodeNameDecryptionRequest,
                                cancellationTokenSource: CancellationTokenSource) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)

        let callbackCompletionSource = CallbackCompletionSource<String>(semaphore: semaphore)

        let successCallback: @convention(c) (UnsafeRawPointer?, ByteArray) -> Void = { ccsPtr, decryptedNameBytes in
            ccsPtr?.unretainedCallbackCompletion(with: String.self)
                   .setResult(value: decryptedNameBytes.to(StringResponse.self).value)
        }

        let ccsPtr = callbackCompletionSource.unretainedPointer

        let callback = AsyncCallback(
            state: ccsPtr,
            on_success: successCallback,
            on_failure: errorCallbackForSemaphore,
            cancellation_token_source_handle: cancellationTokenSource.handle
        )

        let result = try? safeAccess(nodeNameDecryptionRequest) {
            node_decrypt_armored_name(self.handle, $0, callback)
        }.asStatus

        guard result == .ok else {
            ccsPtr.unretainedCallbackCompletion(with: String.self)
                .setError(error: DDKError(failedFunctionName: "node_decrypt_armored_name"))
            return ""
        }

        semaphore.wait()
        if let error = callbackCompletionSource.error { throw error }
        return callbackCompletionSource.value!
    }
}
