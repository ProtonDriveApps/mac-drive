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
import CoreData
import ProtonCoreUtilities
import PDDesktopDevKit
import PDClient
import PDCore
import PDFileProvider
import FileProvider
import ProtonCoreObservability

public class DDKMetadataUpdater {

    private var cachedGetLinkResponses: Atomic<[OperationIdentifier: Link]> = .init([:])
    private var cachedGetRevisionResponses: Atomic<[OperationIdentifier: PDClient.Revision]> = .init([:])
    private var cachedNewFileResponses: Atomic<[OperationIdentifier: (NewFileParameters, NewFile, FileUploadConflict)]> = .init([:])
    private var cachedNewRevisionResponses: Atomic<[OperationIdentifier: NewRevision]> = .init([:])
    private var cachedUpdateRevisionResponses: Atomic<[OperationIdentifier: UpdateRevisionParameters]> = .init([:])

    private let storage: StorageManager

    init(storage: StorageManager) {
        self.storage = storage
    }

    enum ResponseParsingError: String, LocalizedError {
        case wrongIdentifier
        case cannotCreateData
        case wrongOrderOfOperations
        case fileNodeNotFound
        case revisionNotFound
        case noRevisionId
        var errorDescription: String? { rawValue }
    }

    fileprivate struct RevisionConflictResponse: Codable {
        let details: RevisionConflictDetails
        struct RevisionConflictDetails: Codable {
            let conflictLinkID: String
            let conflictRevisionID: String?
            let conflictDraftRevisionID: String?
        }
    }

    // MARK: - Request response body parsing

    func parseResponseBodyResponse(_ response: RequestResponseBodyResponse) {
        do {
            switch response.operationID.type {
            case .download:
                try parseDownloadResponseBody(response: response)

            case .fileUpload:
                try parseFileUploadResponseBody(response: response)

            case .revisionUpload:
                try parseRevisionUploadResponseBody(response: response)

            default:
                return
            }
        } catch {
            // There is a valid scenario in which this can happen:
            // the call failed with an error that we don't expect (like invalid access token).
            // In this case, the response won't be decoded (because we don't expect this response) but it will also mean that
            // the whole operation will fail and we will report this failure to the system.
            Log.warning("Parsing \(response.operationID.type) response body from \(response.operationID.timestamp) for \(response.method) \(response.url) failed with \(error.localizedDescription)", domain: .ddk)
        }
    }

    // MARK: Download parsing

    private func parseDownloadResponseBody(response: RequestResponseBodyResponse) throws {
        // This is the response from RevisionEndpoint
        // we don't send any parameters (all is encoded in the url)
        // we get PDClient.Revision back
        guard let responseData = response.responseBody.data(using: .utf8) else {
            throw ResponseParsingError.cannotCreateData
        }
        let revisionResponse = try JSONDecoder.decapitalisingFirstLetter.decode(
            PDClient.RevisionEndpoint.Response.self, from: responseData
        )
        cachedGetRevisionResponses.mutate { $0[response.operationID] = revisionResponse.revision }
    }

    // MARK: File upload parsing

    /*
     Here are the possible request/response variants:

     1. A new file and revision were created (the no-conflict path, no error handling)
        
        There are two calls parsed in this case:
        a. NewFileEndpoint: NewFileParameters / NewFileResponse
            => means new file was created (with the revision) and is in draft state
        b. UpdateRevisionEndpoint: UpdateRevisionParameters
            => means new draft was commited and made into active state

     2. The existing draft was reused (conflict with the failed previous upload attempt from the same client, error handling path)

        There are three calls parsed in this case:
        a. NewFileEndpoint: NewFileParameters / ConflictResponse (with ConflictDraftRevisionID not null)
            => means file draft already exists
        b. LinkEndpoint: no params / LinkEndpoint.Response
            => means existing draft file was fetched to reuse it (most importantly, to get the keys)
        c. UpdateRevisionEndpoint: UpdateRevisionParameters
            => means existing draft was updated and commited

     3. The exsiting active file was found, so we need to create a new revision
        (conflict with the successful upload from either the same or other client, error handling path)

        There are four calls parsed in this case:
        a. NewFileEndpoint: NewFileParameters / ConflictResponse (with ConflictRevisionID not null, ConflictDraftRevisionID null)
            => means file active already exists
        b. LinkEndpoint: no params / LinkEndpoint.Response
            => means current file and revision were fetched
        c. NewRevisionEndpoint: NewRevisionEndpoint.Response
            => means new revision draft was created
        d. UpdateRevisionEndpoint: UpdateRevisionParameters
            => means new draft was commited
    */

    private enum FileUploadResponse {

        /// Corresponds to `NewFileEndpoint`: `NewFileParameters` / `NewFileResponse`.
        /// If `didIdentifyConflict` is _none_, it means a new file and revision were created.
        /// If `didIdentifyConflict` is _draftAlreadyExists_, it means that a file draft already exists so it can be reused.
        /// If `didIdentifyConflict` is _fileAlreadyCreated_, it means that an active file already exists so the new revision should be added to it.
        /// This goes into `cachedNewFileResponses`.
        case newFileEndpoint(NewFileParameters, NewFile, didIdentifyConflict: FileUploadConflict)

        /// Corresponds to `UpdateRevisionEndpoint`: `UpdateRevisionParameters` / no response.
        /// It means that the revision was commited (aka a draft revision was made active).
        /// It happens in every scenario: either after a new revision was created or after the draft revision was reused.
        /// This goes into `cachedUpdateRevisionResponses`.
        case updateRevisionEndpoint(UpdateRevisionParameters)

        /// Corresponds to `LinkEndpoint`: no params / `LinkEndpoint.Response`.
        /// This happens when there's a conflict, meaning there's an existing node and it was fetched.
        /// If it's in a draft state, we fetch it to reuse it.
        /// If it's in an active state, we will create a push a new revision.
        /// This goes into `cachedGetLinkResponses`.
        case linkEndpoint(Link)

        /// Corresponds to `NewRevisionEndpoint`: `NewRevisionEndpoint.Response`.
        /// This happens when there's an existing node in an active state.
        /// We cannot reuse it, so we create a new revision.
        /// This goes into `cachedNewRevisionResponses`.
        case newRevisionEndpoint(NewRevision)
    }

    enum FileUploadConflict {
        case none
        case draftAlreadyExists
        case fileAlreadyCreated
    }

    private func parseFileUploadResponseBody(response: RequestResponseBodyResponse) throws {
        let fileUploadResponse = try deserializeFileUploadResponse(response: response)
        switch fileUploadResponse {
        case .newFileEndpoint(let newFileParameters, let newFile, let didIdentifyConflict):
            cachedNewFileResponses.mutate { $0[response.operationID] = (newFileParameters, newFile, didIdentifyConflict) }

        case .updateRevisionEndpoint(let updateRevisionParameters):
            cachedUpdateRevisionResponses.mutate { $0[response.operationID] = updateRevisionParameters }

        case .linkEndpoint(let link):
            cachedGetLinkResponses.mutate { $0[response.operationID] = link }

        case .newRevisionEndpoint(let newRevision):
            cachedNewRevisionResponses.mutate { $0[response.operationID] = newRevision }
        }
    }

    private func deserializeFileUploadResponse(
        response: RequestResponseBodyResponse
    ) throws -> FileUploadResponse {
        do {
            let (newFileParameters, newFile, didIdentifyConflict) = try deserializeNewFileEndpoint(response: response)
            return .newFileEndpoint(newFileParameters, newFile, didIdentifyConflict: didIdentifyConflict)
        } catch {
            do {
                let updateRevisionParameters = try deserializeUpdateRevisionEndpoint(response: response)
                return .updateRevisionEndpoint(updateRevisionParameters)
            } catch {
                do {
                    let link = try deserializeLinkEndpoint(response: response)
                    return .linkEndpoint(link)
                } catch {
                    let newRevision = try deserializeNewRevision(response: response)
                    return .newRevisionEndpoint(newRevision)
                }
            }
        }
    }

    private func deserializeNewFileEndpoint(response: RequestResponseBodyResponse) throws -> (NewFileParameters, NewFile, FileUploadConflict) {
        // corresponds to NewFileEndpoint: NewFileParameters and NewFileEndpoint.Response
        guard let requestData = response.requestBody.data(using: .utf8) else {
            throw ResponseParsingError.cannotCreateData
        }
        let newFileParameters = try JSONDecoder().decode(
            PDClient.NewFileParameters.self, from: requestData
        )
        guard let responseData = response.responseBody.data(using: .utf8) else {
            throw ResponseParsingError.cannotCreateData
        }
        let newFile: NewFile
        let didIdentifyConflict: FileUploadConflict
        do {
            newFile = try JSONDecoder.decapitalisingFirstLetter.decode(
                PDClient.NewFileEndpoint.Response.self, from: responseData
            ).file
            didIdentifyConflict = .none
        } catch {
            // corresponds to a special error response from NewFileEndpoint call
            // that indicates the file draft already exists, and can be reused
            let conflictResponse = try JSONDecoder.decapitalisingFirstLetter.decode(
                RevisionConflictResponse.self, from: responseData
            )
            // conflictDraftRevisionID is when the draft is reused, conflictRevisionID is when new revision will be uploaded
            let revisionID: String
            if let conflictDraftRevisionID = conflictResponse.details.conflictDraftRevisionID {
                revisionID = conflictDraftRevisionID
                didIdentifyConflict = .draftAlreadyExists
            } else if let conflictRevisionID = conflictResponse.details.conflictRevisionID {
                revisionID = conflictRevisionID
                didIdentifyConflict = .fileAlreadyCreated
            } else {
                throw ResponseParsingError.noRevisionId
            }
            newFile = NewFile(ID: conflictResponse.details.conflictLinkID, revisionID: revisionID)
        }
        return (newFileParameters, newFile, didIdentifyConflict)
    }

    private func deserializeLinkEndpoint(response: RequestResponseBodyResponse) throws -> Link {
        // corresponds to LinkEndpoint: LinkEndpoint.Response
        // we're not interested in request
        guard let responseData = response.responseBody.data(using: .utf8) else {
            throw ResponseParsingError.cannotCreateData
        }
        return try JSONDecoder.decapitalisingFirstLetter.decode(PDClient.LinkEndpoint.Response.self, from: responseData).link
    }

    // MARK: Revision upload parsing

    private typealias RevisionUploadResponse = Either<NewRevision, UpdateRevisionParameters>

    private func parseRevisionUploadResponseBody(response: RequestResponseBodyResponse) throws {
        let revisionUploadResponse = try deserializeRevisionUploadResponse(response: response)
        switch revisionUploadResponse {
        case .left(let newRevisionResponse):
            cachedNewRevisionResponses.mutate { $0[response.operationID] = newRevisionResponse }

        case .right(let updateRevisionParameters):
            cachedUpdateRevisionResponses.mutate { $0[response.operationID] = updateRevisionParameters }
        }
    }

    private func deserializeRevisionUploadResponse(
        response: RequestResponseBodyResponse
    ) throws -> RevisionUploadResponse {
        do {
            let newRevision = try deserializeNewRevision(response: response)
            return .left(newRevision)
        } catch {
            let parameters = try deserializeUpdateRevisionEndpoint(response: response)
            return .right(parameters)
        }
    }

    private func deserializeNewRevision(response: RequestResponseBodyResponse) throws -> NewRevision {
        // corresponds to NewRevisionEndpoint: NewRevisionEndpoint.Response
        // we're not interested in request
        guard let responseData = response.responseBody.data(using: .utf8) else {
            throw ResponseParsingError.cannotCreateData
        }
        let newRevision: NewRevision
        do {
            newRevision = try JSONDecoder.decapitalisingFirstLetter.decode(
                NewRevisionEndpoint.Response.self, from: responseData
            ).revision
        } catch {
            // corresponds to a special error response from NewRevisionEndpoint call
            // that indicates the revision draft already exists, and can be reused
            let conflictResponse = try JSONDecoder.decapitalisingFirstLetter.decode(
                RevisionConflictResponse.self, from: responseData
            )
            guard let revisionID = conflictResponse.details.conflictDraftRevisionID else {
                throw ResponseParsingError.noRevisionId
            }
            newRevision = NewRevision(ID: revisionID)
        }
        return newRevision
    }

    private func deserializeUpdateRevisionEndpoint(response: RequestResponseBodyResponse) throws -> UpdateRevisionParameters {
        // corresponds to UpdateRevisionEndpoint: UpdateRevisionParameters
        // we're not interested in response
        guard let requestData = response.requestBody.data(using: .utf8) else {
            throw ResponseParsingError.cannotCreateData
        }
        return try JSONDecoder().decode(PDClient.UpdateRevisionParameters.self, from: requestData)
    }

    // MARK: - Metadata update

    /// All the metadata update methods are expected to return this type of error
    enum MetadataUpdateError: LocalizedError {
        case noCachedResponse
        case fieldMissing(missingField: String)
        case metadataUpdateFailed(inner: Swift.Error)

        var errorDescription: String? {
            switch self {
            case .noCachedResponse:
                return "MetadataUpdateError.noCachedResponse"
            case .fieldMissing(let missingField):
                return "MetadataUpdateError.fieldMissing: \(missingField)"
            case .metadataUpdateFailed(let inner):
                return "MetadataUpdateError.metadataUpdateFailed: \(inner.localizedDescription)"
            }
        }
    }

    // MARK: Download metadata update

    func updateMetadataAfterSuccessfulDownload(fileDownload: FileDownloadRequest,
                                               in moc: NSManagedObjectContext) async -> Result<NodeItem, MetadataUpdateError> {
        do {
            guard let revisionMeta = cachedGetRevisionResponses.transform({ $0[fileDownload.operationID] }) else {
                return .failure(MetadataUpdateError.noCachedResponse)
            }
            let nodeIdentity = fileDownload.fileIdentity
            let revisionIdentifier = RevisionIdentifier(
                share: nodeIdentity.shareID.value,
                file: nodeIdentity.nodeID.value,
                revision: revisionMeta.ID,
                // attention! we don't pass nodeIdentity.volumeID.value by design, because our metadata DB
                // is not yet volume-based! this should be changed once DM-433 is done
                volume: ""
            )
            let (node, revision) = try await RevisionScanner.performUpdate(
                in: moc, revisionIdentifier: revisionIdentifier, revisionMeta: revisionMeta, storage: storage
            )
            sendSuccessfulDownloadMetric(for: node, moc: moc)
            return try await moc.perform {
                node.addToRevisions(revision)
                node.activeRevision = revision
                try moc.saveOrRollback()
                return .success(try NodeItem(node: node))
            }
        } catch {
            return .failure(MetadataUpdateError.metadataUpdateFailed(inner: error))
        }
    }

    private func sendSuccessfulDownloadMetric(for node: Node, moc: NSManagedObjectContext) {
        let offlineAvailabilty: Bool? = moc.performAndWait {
            guard node.isAvailableOffline else { return nil }

            return node.isMarkedOfflineAvailable
        }

        guard let offlineAvailabilty else { return }

        let type: DriveKeepDownloadedAttributionType = offlineAvailabilty ? .direct : .inheriting

        ObservabilityEnv.report(
            ObservabilityEvent.keepDownloadedDownloadEvent(type: type)
        )
    }

    // MARK: File upload metadata update

    func updateMetadataAfterSuccessfulFileUpload(
        fileUploaderCreationRequest: FileUploaderCreationRequest,
        fileUploadRequest: FileUploadRequest,
        fileUploadResponse _: PDDesktopDevKit.FileUploadResponse,
        itemTemplate: NSFileProviderItem,
        parent: Folder,
        in moc: NSManagedObjectContext
    ) async -> Result<Node, MetadataUpdateError> {
        guard let (newFileParameters, newFileId, didIdentifyConflict) = cachedNewFileResponses.transform({ $0[fileUploadRequest.operationID] }),
              let updateRevision = cachedUpdateRevisionResponses.transform({ $0[fileUploadRequest.operationID] })
        else {
            return .failure(MetadataUpdateError.noCachedResponse)
        }

        let size = itemTemplate.documentSize?.flatMap { $0.intValue } ?? 0
        let creationDate = itemTemplate.creationDate??.timeIntervalSince1970
                        ?? itemTemplate.contentModificationDate??.timeIntervalSince1970
                        ?? Date.now.timeIntervalSince1970
        let modificationDate = itemTemplate.contentModificationDate??.timeIntervalSince1970 ?? creationDate

        let link: Link

        switch didIdentifyConflict {
        case .none:
            // no conflict means the file was created and commited. We can use newFileParameters here (and only here)
            link = linkNoConflict(
                newFileId, fileUploadRequest, newFileParameters, size, creationDate, modificationDate, updateRevision
            )
        case .draftAlreadyExists:
            // if the conflict was identified, we fetched the node metadata explicitely on the DDK side to have it available here
            guard let linkMeta = cachedGetLinkResponses.transform({ $0[fileUploadRequest.operationID] }) else {
                return .failure(MetadataUpdateError.noCachedResponse)
            }
            guard let fileProperties = linkMeta.fileProperties else {
                return .failure(MetadataUpdateError.fieldMissing(missingField: "Link.fileProperties"))
            }

            let activeRevision = activeRevisionWhenConflict(fileUploadRequest, creationDate, size, updateRevision, newFileId)
            link = linkWhenConflict(linkMeta, updateRevision, fileProperties, activeRevision)
        case .fileAlreadyCreated:
            // if the conflict was identified, we fetched the node metadata for the active node
            guard let linkMeta = cachedGetLinkResponses.transform({ $0[fileUploadRequest.operationID] }) else {
                return .failure(MetadataUpdateError.noCachedResponse)
            }
            guard let fileProperties = linkMeta.fileProperties else {
                return .failure(MetadataUpdateError.fieldMissing(missingField: "Link.fileProperties"))
            }

            let activeRevision = activeRevisionWhenConflict(fileUploadRequest, creationDate, size, updateRevision, newFileId)
            link = linkWhenConflict(linkMeta, updateRevision, fileProperties, activeRevision)
        }
        do {
            return try await moc.perform {
                let node = self.storage.updateLink(link, using: moc)
                node.isInheritingOfflineAvailable = parent.isAvailableOffline
                try moc.saveOrRollback()
                return .success(node)
            }
        } catch {
            return .failure(MetadataUpdateError.metadataUpdateFailed(inner: error))
        }
    }

    private func activeRevisionWhenConflict(
        _ fileUploadRequest: FileUploadRequest,
        _ creationDate: TimeInterval,
        _ size: Int,
        _ updateRevision: UpdateRevisionParameters,
        _ newFileId: NewFile
    ) -> RevisionShort {
        // this is only available if there was a new revision creation and not a draft revision reusing
        if let newRevision = cachedNewRevisionResponses.transform({ $0[fileUploadRequest.operationID] }) {
            return RevisionShort(
                ID: newRevision.ID,
                createTime: creationDate,
                size: size,
                manifestSignature: updateRevision.ManifestSignature,
                signatureAddress: updateRevision.SignatureAddress,
                state: .active,
                thumbnail: 0
            )

        // lack of the new revision creation means a draft revision was reused
        } else {
            return RevisionShort(
                ID: newFileId.revisionID,
                createTime: creationDate,
                size: size,
                manifestSignature: updateRevision.ManifestSignature,
                signatureAddress: updateRevision.SignatureAddress,
                state: .active,
                thumbnail: 0
            )
        }
    }

    private func linkWhenConflict(
        _ linkMeta: Link,
        _ updateRevision: UpdateRevisionParameters,
        _ fileProperties: FileProperties,
        _ activeRevision: RevisionShort
    ) -> Link {
        Link(
            linkID: linkMeta.linkID,
            parentLinkID: linkMeta.parentLinkID,
            // attention! we don't pass linkMeta.volumeID by design,
            // because our metadata DB is not yet volume-based! this should be changed once DM-433 is done
            volumeID: "",
            type: linkMeta.type,
            name: linkMeta.name,
            nameSignatureEmail: linkMeta.nameSignatureEmail,
            hash: linkMeta.hash,
            state: .active,
            expirationTime: linkMeta.expirationTime,
            size: linkMeta.size,
            MIMEType: linkMeta.MIMEType,
            attributes: linkMeta.attributes,
            permissions: linkMeta.permissions,
            nodeKey: linkMeta.nodeKey,
            nodePassphrase: linkMeta.nodePassphrase,
            nodePassphraseSignature: linkMeta.nodePassphraseSignature,
            signatureEmail: linkMeta.signatureEmail,
            createTime: linkMeta.createTime,
            modifyTime: linkMeta.modifyTime,
            trashed: linkMeta.trashed,
            sharingDetails: linkMeta.sharingDetails,
            nbUrls: linkMeta.nbUrls,
            activeUrls: linkMeta.activeUrls,
            urlsExpired: linkMeta.urlsExpired,
            XAttr: updateRevision.XAttr,
            fileProperties: FileProperties(contentKeyPacket: fileProperties.contentKeyPacket,
                                           contentKeyPacketSignature: fileProperties.contentKeyPacketSignature,
                                           activeRevision: activeRevision),
            folderProperties: linkMeta.folderProperties,
            documentProperties: linkMeta.documentProperties
        )
    }

    // swiftlint:disable:next function_parameter_count
    private func linkNoConflict(
        _ newFileId: NewFile,
        _ fileUploadRequest: FileUploadRequest,
        _ newFileParameters: NewFileParameters,
        _ size: Int,
        _ creationDate: TimeInterval,
        _ modificationDate: TimeInterval,
        _ updateRevision: UpdateRevisionParameters
    ) -> Link {
        let activeRevision = RevisionShort(
            ID: newFileId.revisionID,
            createTime: creationDate,
            size: size,
            manifestSignature: updateRevision.ManifestSignature,
            signatureAddress: updateRevision.SignatureAddress,
            state: .active,
            thumbnail: 0
        )
        return Link(
            linkID: newFileId.ID,
            parentLinkID: fileUploadRequest.parentFolderIdentity.nodeID.value,
            // attention! we don't pass fileUploadRequest.parentFolderIdentity.volumeID.value by design,
            // because our metadata DB is not yet volume-based! this should be changed once DM-433 is done
            volumeID: "",
            type: .file,
            name: newFileParameters.Name,
            nameSignatureEmail: newFileParameters.SignatureAddress,
            hash: newFileParameters.Hash,
            state: .active,
            expirationTime: nil,
            size: size,
            MIMEType: newFileParameters.MIMEType,
            attributes: 1, // taken from the observed network response, not used in NodeItem creation
            permissions: 7, // taken from the observed network response, not used in NodeItem creation
            nodeKey: newFileParameters.NodeKey,
            nodePassphrase: newFileParameters.NodePassphrase,
            nodePassphraseSignature: newFileParameters.NodePassphraseSignature,
            signatureEmail: newFileParameters.SignatureAddress,
            createTime: creationDate,
            modifyTime: modificationDate,
            trashed: nil,
            sharingDetails: nil,
            nbUrls: 0,
            activeUrls: 0,
            urlsExpired: 0,
            XAttr: updateRevision.XAttr,
            fileProperties: FileProperties(contentKeyPacket: newFileParameters.ContentKeyPacket,
                                           contentKeyPacketSignature: newFileParameters.ContentKeyPacketSignature,
                                           activeRevision: activeRevision),
            folderProperties: nil,
            documentProperties: nil
        )
    }

    // MARK: Revision upload metadata update

    func updateMetadataAfterSuccessfulRevisionUpload(
        item: NSFileProviderItem,
        fileUploaderCreationRequest: FileUploaderCreationRequest,
        revisionUploadRequest: RevisionUploadRequest,
        revision: PDDesktopDevKit.Revision,
        in moc: NSManagedObjectContext
    ) async -> Result<NodeItem, MetadataUpdateError> {
        do {
            guard let updateRevision = cachedUpdateRevisionResponses.transform({ $0[revisionUploadRequest.operationID] })
            else {
                return .failure(MetadataUpdateError.noCachedResponse)
            }

            let createTime = item.creationDate.flatMap { $0?.timeIntervalSince1970 } ?? Date.now.timeIntervalSince1970

            let revisionMeta = PDClient.Revision(
                ID: revision.revisionID.value,
                createTime: createTime,
                size: Int(revision.size),
                manifestSignature: updateRevision.ManifestSignature,
                signatureAddress: updateRevision.SignatureAddress,
                state: .active,
                blocks: [],
                thumbnail: 0,
                thumbnailHash: nil,
                thumbnailDownloadUrl: nil,
                XAttr: updateRevision.XAttr
            )
            let revisionIdentifier = RevisionIdentifier(
                share: revisionUploadRequest.fileIdentity.shareID.value,
                file: revision.fileID.value,
                revision: revision.revisionID.value,
                // attention! we don't pass revision.volumeID.value by design,
                // because our metadata DB is not yet volume-based! this should be changed once DM-433 is done
                volume: ""
            )
            let (file, revision) = try await RevisionScanner.performUpdate(
                in: moc, revisionIdentifier: revisionIdentifier, revisionMeta: revisionMeta, storage: storage
            )
            let nodeItem = try await moc.perform {
                file.addToRevisions(revision)
                file.activeRevision = revision
                try moc.saveOrRollback()
                return try NodeItem(node: file)
            }
            return .success(nodeItem)
        } catch {
            return .failure(MetadataUpdateError.metadataUpdateFailed(inner: error))
        }
    }
}
