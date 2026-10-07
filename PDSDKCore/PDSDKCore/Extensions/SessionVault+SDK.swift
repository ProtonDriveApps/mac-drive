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
import ProtonCoreDataModel
import PDCore
import ProtonDriveSDK

extension SessionVault: @retroactive AccountClientProtocol, @unchecked Sendable {
    public func getAddress(addressId: String) -> AccountClientAddress? {
        let address = getProtonCoreAddress(addressId: addressId)
        return address?.mapToSDK()
    }

    public func getDefaultAddress() -> AccountClientAddress? {
        return currentAddress()?.mapToSDK()
    }

    public func getAddressPrimaryPrivateKey(addressId: String) -> Data? {
        guard let address = getProtonCoreAddress(addressId: addressId) else { return nil }
        guard let primaryKey = address.activeKeys.first(where: { $0.primary == 1 }) else {
            Log.warning("There is no associated primary key for the \(addressId)", domain: .sdk)
            return nil
        }
        do {
            return try unlockedAddressPrivateKeyData(for: primaryKey)
        } catch {
            Log.error("Retrieve private key data failed", error: error, domain: .sdk)
            return nil
        }
    }

    public func getAddressPrivateKeys(addressId: String) -> [Data]? {
        guard let address = getProtonCoreAddress(addressId: addressId) else { return nil }
        do {
            return try address.activeKeys.map { key in
                try unlockedAddressPrivateKeyData(for: key)
            }
        } catch {
            Log.error("Retrieve private key data failed", error: error, domain: .sdk)
            return nil
        }
    }

    public func getAddressPublicKeysRequest(emailAddress: String) -> [Data] {
        return getPublicKeys(for: emailAddress)
            .map { Data($0.utf8) }
    }

    // MARK: - Private

    private func getProtonCoreAddress(addressId: String) -> Address? {
        let address = getAddress(withId: addressId)
        if address == nil {
            Log.warning("There is no address for \(addressId)", domain: .sdk)
        }
        return address
    }
}

fileprivate extension Address {
    func mapToSDK() -> AccountClientAddress {
        let status: AccountClientAddress.Status = {
            switch self.status {
            case .disabled:
                return .disabled
            case .enabled:
                return .enabled
            }
        }()
        return AccountClientAddress(
            addressID: addressID,
            order: Int32(order),
            emailAddress: email,
            status: status,
            primaryKeyIndex: Int32(keys.firstIndex(where: { $0.primary == 1 }) ?? 0),
            keys: keys.map { key in
                AccountClientAddress.Key(
                    addressID: addressID,
                    addressKeyID: key.keyID,
                    isActive: key.active == 1,
                    isAllowedForEncryption: key.isAllowedForEncryption,
                    isAllowedForVerification: key.isAllowedForVerification
                )
            }
        )
    }
}

fileprivate extension Key {
    var isAllowedForEncryption: Bool {
        KeyFlags(rawValue: UInt8(truncating: keyFlags as NSNumber)).contains(.encryptNewData)
    }

    var isAllowedForVerification: Bool {
        KeyFlags(rawValue: UInt8(truncating: keyFlags as NSNumber)).contains(.verifySignatures)
    }
}
