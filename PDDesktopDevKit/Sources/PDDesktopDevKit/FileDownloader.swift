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

final class FileDownloader {

    let handle: ObjectHandle

    init(protonDriveClient: ProtonDriveClient, cancellationTokenSource: CancellationTokenSource) async throws {
        handle = try await invokeDDK(objectHandle: protonDriveClient.handle,
                                     request: Empty(),
                                     cancellationTokenSource: cancellationTokenSource,
                                     functionInvocation: downloader_create,
                                     successCallback: { tcsPtr, downloaderHandleBytes in
            let downloaderHandle = downloaderHandleBytes.to(IntResponse.self).value
            tcsPtr?.unretainedTaskCompletion(with: ObjectHandle.self)
                   .setResult(value: ObjectHandle(downloaderHandle))
        })
    }

    public func downloadFile(fileDownloadRequest: FileDownloadRequest,
                             cancellationTokenSource: CancellationTokenSource,
                             onProgressUpdate: @escaping BytesProgressCallback) async throws -> VerificationStatus {
        try await invokeDDKWithProgress(objectHandle: handle,
                                        onBytesProgressUpdate: onProgressUpdate,
                                        cancellationTokenSource: cancellationTokenSource,
                                        request: fileDownloadRequest,
                                        functionInvocation: downloader_download_file,
                                        successCallback: { tcsPtr, responseBytes in
            let verificationStatusResponse = responseBytes.to(VerificationStatusResponse.self)
            tcsPtr?.unretainedTaskCompletion(with: VerificationStatus.self)
                   .setResult(value: verificationStatusResponse.verificationStatus)
        })
    }

    deinit {
        downloader_free(handle)
    }
}
