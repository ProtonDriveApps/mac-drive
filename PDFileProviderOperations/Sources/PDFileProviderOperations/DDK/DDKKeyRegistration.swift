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
import PDDesktopDevKit
import PDCore
import ProtonCoreCryptoGoInterface
import ProtonCoreDataModel
import ProtonCoreLog
import ProtonCoreUtilities

fileprivate extension Key {
    var isAllowedForEncryption: Bool {
        KeyFlags(rawValue: UInt8(truncating: keyFlags as NSNumber)).contains(.encryptNewData)
    }
}

enum DDKKeyRegistration {

    static func processKeyCacheMiss(
        keyCacheMiss: KeyCacheMissMessage,
        protonDriveClientAccessor: Atomic<WeakReference<ProtonDriveClient>>,
        storage: StorageManager
    ) -> Bool {
        let protonDriveClientReference = protonDriveClientAccessor.value
        guard protonDriveClientReference.reference != nil else {
            Log.warning("Failed to register a key \(keyCacheMiss) because there is no protonDriveClient",
                        domain: .fileProvider)
            return false
        }
        let moc = storage.backgroundContext
        do {
            return try moc.performAndWait {
                let (share, volume) = try storage.getMainShareAndVolume(in: moc)
                if keyCacheMiss.holderID == share.id,
                   keyCacheMiss.holderName == "share",
                   !keyCacheMiss.hasContextID,
                   !keyCacheMiss.hasContextName {
                    return try Self.registerShareKey(share, protonDriveClientReference)
                }
                // sanity check that we're indeed asked about the node keys here
                if keyCacheMiss.holderName != "node",
                   keyCacheMiss.contextName != "drive.volume",
                   keyCacheMiss.contextID != volume.id {
                    Log.error("Key requested by DDK for registration does not seem to be the node key",
                              domain: .fileProvider)
                    return false
                }
                // attention! we don't use volume.id in NodeIdentifier by design,
                // because our metadata DB is not yet volume-based!
                // this should be changed once DM-433 is done
                let nodeIdentifier = NodeIdentifier(keyCacheMiss.holderID, share.id, "")
                guard let node = storage.fetchNode(id: nodeIdentifier, moc: moc) else {
                    Log.warning("Failed to find a node key key to register for \(nodeIdentifier)",
                                domain: .fileProvider)
                    return false
                }
                return try registerNodeKeys(node, volume.id, protonDriveClientReference)
            }
        } catch {
            Log.warning("Failed to register a key \(keyCacheMiss) because of error \(error.localizedDescription)",
                        domain: .fileProvider)
            return false
        }
    }

    // MARK: User key registration

    static func registerUserKey(_ key: Key, _ passphrase: String, _ protonApiSession: ProtonApiSession) -> Bool {
        let armoredUserKey = ArmoredUserKey.with {
            $0.keyID.value = key.keyID
            $0.armoredKeyData = key.privateKey.data(using: .utf8) ?? Data()
            $0.passphrase = passphrase
        }

        let registerUserKeyStatus = protonApiSession.registerArmoredLockedUserKey(armoredUserKey: armoredUserKey)
        return registerUserKeyStatus == .ok
    }

    // MARK: Address keys registration

    static func registerAddressKeys(_ protonApiSession: ProtonApiSession, _ sessionVault: SessionVault) async {
        let operationBegin = Date.now.timeIntervalSince1970
        let processedKeysPerAddress = await sessionVault.allAddressesFullInfo
            .filter { $0.status == .enabled }
            .parallelMap { (address) -> AddressKeyRegistrationRequest? in
                await addressKeyRegistrationRequest(address, sessionVault)
            }
            .compactMap { $0 } // to filter out the nils from above
            .map { addressKeyRegistrationRequest in
                let wereAddressKeysRegisteredSuccessfully = registerAddressKeyInDDK(addressKeyRegistrationRequest, protonApiSession)
                return (addressKeyRegistrationRequest.keys.count, wereAddressKeysRegisteredSuccessfully)
            }
        let operationEnd = Date.now.timeIntervalSince1970
        let numberOfProcessedKeys = processedKeysPerAddress.reduce((succeeded: 0, failed: 0)) { partialResult, elem in
            let (keysCount, wasSuccessful) = elem
            if wasSuccessful {
                return (succeeded: partialResult.succeeded + keysCount, failed: partialResult.failed)
            } else {
                return (succeeded: partialResult.succeeded, failed: partialResult.failed + keysCount)
            }
        }
        Log.info("Address keys cache populating took \(operationEnd - operationBegin) seconds. Total: \(numberOfProcessedKeys.succeeded + numberOfProcessedKeys.failed). Succeeded: \(numberOfProcessedKeys.succeeded). Failed: \(numberOfProcessedKeys.failed)", domain: .fileProvider)
    }

    private static func registerAddressKeyInDDK(
        _ addressKeyRegistrationRequest: AddressKeyRegistrationRequest,
        _ protonApiSession: ProtonApiSession
    ) -> Bool {
        let registerAddressKeysStatus = protonApiSession.registerAddressKeys(
            addressKeyRegistrationRequest: addressKeyRegistrationRequest
        )
        let wereAddressKeysRegisteredSuccessfully = registerAddressKeysStatus == .ok
        if !wereAddressKeysRegisteredSuccessfully {
            // The app can function without address key being registered
            // DDK will ask the Proton BE for it. It's not efficient (additional calls), but it works
            Log.warning("Failed to register key for address \(addressKeyRegistrationRequest.addressID.value)",
                        domain: .fileManager)
        }
        return wereAddressKeysRegisteredSuccessfully
    }

    private static func addressKeyRegistrationRequest(
        _ address: Address, _ sessionVault: SessionVault
    ) async -> AddressKeyRegistrationRequest? {
        let keys = await address.activeKeys
            .parallelMap { key in
                try? Self.addressKeyWithData(key, sessionVault: sessionVault)
            }
            .compactMap { $0 } // to filter out the nils from above

        guard !keys.isEmpty else { return nil }
        return AddressKeyRegistrationRequest.with {
            $0.addressID.value = address.addressID
            $0.keys = keys
        }
    }

    private static func addressKeyWithData(
        _ key: Key, sessionVault: SessionVault
    ) throws -> AddressKeyWithData? {
        let lockedAddressKey = try executeAndUnwrap { CryptoGo.CryptoNewKeyFromArmored(key.privateKey, &$0) }
        let decryptedAddressPassphrase = try sessionVault.addressPassphrase(for: key)
        let unlockedAddressKey = try lockedAddressKey.unlock(decryptedAddressPassphrase.data(using: .utf8))
        let addressKeyRawUnlockedData = try unlockedAddressKey.serialize()

        return AddressKeyWithData.with {
            $0.addressKeyID.value = key.keyID
            $0.isPrimary = key.primary == 1
            $0.isAllowedForEncryption = key.isAllowedForEncryption
            $0.rawUnlockedData = addressKeyRawUnlockedData
        }
    }

    // MARK: Share key registration

    static func registerShareKey(
        _ share: PDCore.Share, _ protonDriveClient: WeakReference<ProtonDriveClient>
    ) throws -> Bool {
        let request = try shareKeyRegistrationRequest(share)
        return registerShareKeyInDDK(request, protonDriveClient)
    }

    private static func registerShareKeyInDDK(
        _ request: ShareKeyRegistrationRequest,
        _ protonDriveClient: WeakReference<ProtonDriveClient>
    ) -> Bool {
        guard let protonDriveClient = protonDriveClient.reference else {
            Log.warning("Failed to register a share key \(request.shareID.value) because there is no protonDriveClient",
                        domain: .fileProvider)
            return false
        }
        let status = protonDriveClient.registerShareKey(shareKeyRegistrationRequest: request)
        if status != .ok {
            Log.warning("Failed to register key for share \(request.shareID.value) within the DDK",
                        domain: .fileProvider)
            return false
        } else {
            return true
        }
    }

    private static func shareKeyRegistrationRequest(_ share: PDCore.Share) throws -> ShareKeyRegistrationRequest {
        let lockedShareKey = try executeAndUnwrap { CryptoGo.CryptoNewKeyFromArmored(share.key, &$0) }
        let decryptedSharePassphrase = try share.decryptPassphrase()
        let unlockedShareKey = try lockedShareKey.unlock(decryptedSharePassphrase.data(using: .utf8))
        let shareKeyRawUnlockedData = try unlockedShareKey.serialize()
        return ShareKeyRegistrationRequest.with {
            $0.shareID.value = share.id
            $0.shareKeyRawUnlockedData = shareKeyRawUnlockedData
        }
    }

    // MARK: Node key registration

    static func registerNodeKeys(
        _ node: Node, _ volumeID: String, _ protonDriveClient: WeakReference<ProtonDriveClient>
    ) throws -> Bool {
        let request = try nodeKeysRegistrationRequest(node: node, volumeID: volumeID)
        return registerNodeKeysInDDK(request, protonDriveClient)
    }

    private static func nodeKeysRegistrationRequest(
        node: Node, volumeID: String
    ) throws -> NodeKeysRegistrationRequest {
        let nodeIdentity = NodeIdentity.with {
            $0.nodeID.value = node.id
            $0.shareID.value = node.shareID
            $0.volumeID.value = volumeID
        }
        let lockedNodeKey = try executeAndUnwrap { CryptoGo.CryptoNewKeyFromArmored(node.nodeKey, &$0) }
        let decryptedNodePassphrase = try node.decryptPassphrase()
        let unlockedNodeKey = try lockedNodeKey.unlock(decryptedNodePassphrase.data(using: .utf8))
        let nodeKeyRawUnlockedData = try unlockedNodeKey.serialize()
        let contentKeyRawUnlockedData: Data?
        if let file = node as? File {
            contentKeyRawUnlockedData = try file.decryptContentKeyPacket()
        } else {
            contentKeyRawUnlockedData = nil
        }
        let hashKeyRawUnlockedData: Data?
        if let folder = node as? Folder {
            hashKeyRawUnlockedData = try folder.decryptNodeHashKey().data(using: .utf8)
        } else {
            hashKeyRawUnlockedData = nil
        }
        return NodeKeysRegistrationRequest.with {
            $0.nodeIdentity = nodeIdentity
            $0.nodeKeyRawUnlockedData = nodeKeyRawUnlockedData
            if let contentKeyRawUnlockedData {
                $0.contentKeyRawUnlockedData = contentKeyRawUnlockedData
            }
            if let hashKeyRawUnlockedData {
                $0.hashKeyRawUnlockedData = hashKeyRawUnlockedData
            }
        }
    }

    private static func registerNodeKeysInDDK(
        _ request: NodeKeysRegistrationRequest,
        _ protonDriveClient: WeakReference<ProtonDriveClient>
    ) -> Bool {
        guard let protonDriveClient = protonDriveClient.reference else {
            Log.warning("Failed to register a node key \(request.nodeIdentity) because there is no protonDriveClient",
                        domain: .fileProvider)
            return false
        }
        let status = protonDriveClient.registerNodeKeys(nodeKeysRegistrationRequest: request)
        if status != .ok {
            Log.warning("Failed to register key for node \(request.nodeIdentity.nodeID.value) within the DDK",
                        domain: .fileProvider)
            return false
        } else {
            return true
        }
    }
}
