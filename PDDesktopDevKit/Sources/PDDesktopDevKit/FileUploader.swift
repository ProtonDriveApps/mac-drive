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

import ProtonDriveSdk
import ProtonDriveProtos

final class FileUploader {

    let handle: ObjectHandle

    init(protonDriveClient: ProtonDriveClient,
         fileUploaderCreationRequest: FileUploaderCreationRequest,
         cancellationTokenSource: CancellationTokenSource) async throws {
        handle = try await invokeDDK(objectHandle: protonDriveClient.handle,
                                     request: fileUploaderCreationRequest,
                                     cancellationTokenSource: cancellationTokenSource,
                                     functionInvocation: uploader_create,
                                     successCallback: { tcsPtr, uploaderHandleBytes in
            let uploaderHandleBytes = uploaderHandleBytes.to(IntResponse.self).value
            tcsPtr?.unretainedTaskCompletion(with: ObjectHandle.self)
                   .setResult(value: ObjectHandle(uploaderHandleBytes))
        })
    }

    func uploadFile(fileUploadRequest: FileUploadRequest,
                    cancellationTokenSource: CancellationTokenSource,
                    onProgressUpdate: @escaping BytesProgressCallback) async throws -> FileUploadResponse {

        try await invokeDDKWithProgress(objectHandle: handle,
                                        onBytesProgressUpdate: onProgressUpdate,
                                        cancellationTokenSource: cancellationTokenSource,
                                        request: fileUploadRequest,
                                        functionInvocation: uploader_upload_file_or_revision,
                                        successCallback: { tcsPtr, uploadResponseBytes in
            let response = uploadResponseBytes.to(FileUploadResponse.self)
            tcsPtr?.unretainedTaskCompletion(with: FileUploadResponse.self)
                   .setResult(value: response)
        })
    }

    func uploadRevision(revisionUploadRequest: RevisionUploadRequest,
                        cancellationTokenSource: CancellationTokenSource,
                        onProgressUpdate: @escaping BytesProgressCallback) async throws -> Revision {

        try await invokeDDKWithProgress(objectHandle: handle,
                                        onBytesProgressUpdate: onProgressUpdate,
                                        cancellationTokenSource: cancellationTokenSource,
                                        request: revisionUploadRequest,
                                        functionInvocation: uploader_upload_revision,
                                        successCallback: { tcsPtr, uploadResponseBytes in
            let response: Revision = uploadResponseBytes.to(Revision.self)
            tcsPtr?.unretainedTaskCompletion(with: Revision.self)
                   .setResult(value: response)
        })
    }

    deinit {
        uploader_free(handle)
    }

}
