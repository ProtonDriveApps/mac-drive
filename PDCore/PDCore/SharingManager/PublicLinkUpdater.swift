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
import PDClient

public protocol PublicLinkUpdater {
    func updatePublicLink(_ identifier: PublicLinkIdentifier, node: NodeIdentifier, with details: UpdateShareURLDetails) async throws
}

public final class RemoteCachingPublicLinkUpdater: PublicLinkUpdater {

    private let client: Client
    private let storage: StorageManager
    private let signersKitFactory: SignersKitFactoryProtocol

    public init(client: Client, storage: StorageManager, signersKitFactory: SignersKitFactoryProtocol) {
        self.client = client
        self.storage = storage
        self.signersKitFactory = signersKitFactory
    }

    public func updatePublicLink(_ identifier: PublicLinkIdentifier, node: NodeIdentifier, with details: UpdateShareURLDetails) async throws {
        Log.info("SharingManager.updateSecureLink, will update a secure link details \(node)", domain: .sharing)
        let context = storage.backgroundContext

        let shareURL = try await context.perform {
            guard let shareURL = ShareURL.fetch(id: identifier.id, in: context) else {
                throw ShareURL.InvalidState(message: "No ShareURL with id: \(identifier.id) found")
            }
            return shareURL
        }

        let shareUrlMeta = try await updateShareURL(shareURL: shareURL, node: node, details: details)

        return try await context.perform {
            self.storage.updateShareURL(shareUrlMeta, in: context)
            try context.saveOrRollback()
        }
    }

    /// Internal for unit tests only, returns metadata
    func updateShareURL(shareURL: ShareURL, node: NodeIdentifier, details: UpdateShareURLDetails) async throws -> ShareUrlMeta {
        switch (details.password, details.duration) {
            // Call pure update expiration with value
        case (.unchanged, .expiring(let duration)):
            try await updatePureDateExpiration(shareURL: shareURL, expirationDuration: Int(duration))

            // Call pure update expiration with nil
        case (.unchanged, .nonExpiring):
            try await updatePureDateExpiration(shareURL: shareURL, expirationDuration: nil)

            // Call pure update password
        case (.updated(let password), .unchanged):
            try await updatePurePassword(shareURL: shareURL, newPassword: password)

        case (.updated(let password), .expiring(let duration)):
            // Call mixed update password and expiration
            try await updateMixedPasswordExpiration(shareURL: shareURL, newPassword: password, expirationDuration: Int(duration))

            // Call mixed update password and expiration
        case (.updated(let password), .nonExpiring):
            try await updateMixedPasswordExpiration(shareURL: shareURL, newPassword: password, expirationDuration: nil)

            // (.unchanged, .unchanged)
        default:
            fatalError("Should not happen, (.unchanged, .unchanged)")
        }
    }

    private func updatePureDateExpiration(shareURL: ShareURL, expirationDuration: Int?) async throws -> ShareUrlMeta {
        let context = storage.backgroundContext

        let (parameters, shareID, shareURLID) = await context.perform {
            return (
                EditShareURLExpiration(expirationDuration: expirationDuration),
                shareURL.share.id,
                shareURL.id
            )
        }

        return try await client.updateShareURL(shareURLID: shareURLID, shareID: shareID, parameters: parameters)
    }

    private func updatePurePassword(shareURL: ShareURL, newPassword: String) async throws -> ShareUrlMeta {
        guard newPassword.count >= Constants.minSharedLinkRandomPasswordSize,
              newPassword.count <= Constants.maxSharedLinkPasswordLength else {
            throw DriveError("The new Public Link password does not fit Public Link password requirements.")
        }
        let context = storage.backgroundContext

        let modulusResponse = try await client.getModulusSRP()

        let (parameters, shareID, shareURLID) = try await context.perform {
            return (
                try self.makeUpdatedPassword(share: shareURL.share, urlPassword: newPassword, modulus: modulusResponse.modulus, modulusID: modulusResponse.modulusID),
                shareURL.share.id,
                shareURL.id
            )
        }

        return try await client.updateShareURL(shareURLID: shareURLID, shareID: shareID, parameters: parameters)
    }

    private func updateMixedPasswordExpiration(shareURL: ShareURL, newPassword: String, expirationDuration: Int?) async throws -> ShareUrlMeta {
        guard newPassword.count >= Constants.minSharedLinkRandomPasswordSize,
              newPassword.count <= Constants.maxSharedLinkPasswordLength else {
            throw DriveError("The new Public Link password does not fit Public Link password requirements.")
        }
        let context = storage.backgroundContext

        let modulusResponse = try await client.getModulusSRP()

        let (expirationParameters, passwordParameters, shareID, shareURLID) = try await context.perform {
            return (
                EditShareURLExpiration(expirationDuration: expirationDuration),
                try self.makeUpdatedPassword(share: shareURL.share, urlPassword: newPassword, modulus: modulusResponse.modulus, modulusID: modulusResponse.modulusID),
                shareURL.share.id,
                shareURL.id
            )
        }

        let parameters = EditShareURLPasswordAndDuration(expirationParameters, passwordParameters)
        return try await client.updateShareURL(shareURLID: shareURLID, shareID: shareID, parameters: parameters)
    }

    private func makeUpdatedPassword(share: Share, urlPassword: String, modulus: String, modulusID: String) throws -> EditShareURLPassword {
        let addressID = try share.getAddressID()
        let currentAddressKey = try signersKitFactory.make(forAddressID: addressID).addressKey.publicKey
        let encryptedPassword = try Encryptor.encrypt(urlPassword, key: currentAddressKey)

        let srpRandomPassword = try Decryptor.srpForPassword(urlPassword, modulus: modulus)
        let srpPasswordSalt = srpRandomPassword.salt.base64EncodedString()
        let srpPasswordVerifier = srpRandomPassword.verifier.base64EncodedString()

        let shareDecryptionKeys = try share.getShareCreatorDecryptionKeys()
        let shareSessionKey = try Decryptor.decryptSessionKey(share.passphrase.forceUnwrap(), decryptionKeys: shareDecryptionKeys)
        let bcryptedRandomPassword = try Decryptor.bcryptPassword(urlPassword)
        let shareKeyPacket = try Decryptor.encryptSessionKey(shareSessionKey, with: bcryptedRandomPassword.hash).base64EncodedString()
        let sharePasswordSalt = bcryptedRandomPassword.salt.base64EncodedString()

        let flag: ShareURLMeta.Flags = urlPassword.count == Constants.minSharedLinkRandomPasswordSize ? .newRandomPassword : .newCustomPassword

        return EditShareURLPassword(
            urlPasswordSalt: srpPasswordSalt,
            sharePasswordSalt: sharePasswordSalt,
            srpVerifier: srpPasswordVerifier,
            srpModulusID: modulusID,
            flags: flag,
            sharePassphraseKeyPacket: shareKeyPacket,
            encryptedUrlPassword: encryptedPassword
        )
    }
}
