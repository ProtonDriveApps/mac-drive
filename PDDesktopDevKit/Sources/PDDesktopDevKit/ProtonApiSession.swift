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
import SwiftProtobuf

extension Int32 {
    var asStatus: Status { Status(rawValue: Int(exactly: self)!)! }
}

public protocol ProtonApiSessionProtocol: AnyObject {
    var handle: Int { get }
}

public final class ProtonApiSession: ProtonApiSessionProtocol {

    public private(set) var handle: ObjectHandle = 0

    fileprivate init(handle: ObjectHandle) {
        self.handle = handle
    }

    deinit {
        session_free(self.handle)
    }

    public static func beginSession(
        sessionBeginRequest: SessionBeginRequest,
        cancellationTokenSource: CancellationTokenSource,
        onResponseBodyReceived: @escaping ResponseBodyCallback,
        onKeyCacheMiss: @escaping OnKeyCacheMissCallback,
        onTokensRefreshed: @escaping TokensRefreshedCallback
    ) async throws -> ProtonApiSession {
        try await invokeDDKWithResponseBodyAndKeyCacheMissAndTokenRefreshed(
            objectHandle: .zero,
            onResponseBodyReceived: onResponseBodyReceived,
            onKeyCacheMiss: onKeyCacheMiss,
            onTokensRefreshed: onTokensRefreshed,
            cancellationTokenSource: cancellationTokenSource,
            request: sessionBeginRequest,
            functionInvocation: session_begin,
            successCallback: { tcsPtr, sessionHandleBytes in
                let handle = sessionHandleBytes.to(IntResponse.self).value
                tcsPtr?.unretainedTaskCompletion(with: ProtonApiSession.self)
                       .setResult(value: ProtonApiSession(handle: Int(handle)))
            }
        )
    }

    public static func resumeSession(
        sessionResumeRequest: SessionResumeRequest,
        onResponseBodyReceived: @escaping ResponseBodyCallback,
        onKeyCacheMiss: @escaping OnKeyCacheMissCallback,
        onTokensRefreshed: @escaping TokensRefreshedCallback
    ) -> ProtonApiSession? {
        var sessionHandle = 0

        let responseReceivedSource = ResponseBodyReceivedSource(onResponseBodyReceived: onResponseBodyReceived)
        let keyCacheMissedSource = KeyCacheMissedSource(onKeyCacheMissed: onKeyCacheMiss)
        let tokensRefreshedSource = TokensRefreshedSource(onTokensRefreshed: onTokensRefreshed)
        
        let rbrPtr = responseReceivedSource.retainedPointer
        let kcmsPtr = keyCacheMissedSource.retainedPointer
        let tokPtr = tokensRefreshedSource.retainedPointer
        
        let responseBodyCallback = ProtonDriveSdk.Callback(
            state: rbrPtr, callback: responseBodyCallback
        )
        let keyCacheMissedCallback = ProtonDriveSdk.BooleanCallback(
            state: kcmsPtr, callback: onKeyCacheMissedCallback
        )
        let tokensRefreshedCallback = ProtonDriveSdk.Callback(
            state: tokPtr, callback: tokensRefreshedCallback
        )

        let result = try? safeAccess(sessionResumeRequest) {
            session_resume($0, responseBodyCallback, keyCacheMissedCallback, tokensRefreshedCallback, &sessionHandle)
        }.asStatus
        guard result == .ok else { return nil }
        return ProtonApiSession(handle: Int(sessionHandle))
    }
    
    public static func renewSession(
        oldSession: ProtonApiSessionProtocol,
        sessionRenewRequest: SessionRenewRequest,
        onTokensRefreshed: @escaping TokensRefreshedCallback
    ) -> ProtonApiSession? {
        var sessionHandle = 0
        
        let tokensRefreshedSource = TokensRefreshedSource(onTokensRefreshed: onTokensRefreshed)
        let tokPtr = tokensRefreshedSource.retainedPointer
        let tokensRefreshedCallback = ProtonDriveSdk.Callback(
            state: tokPtr, callback: tokensRefreshedCallback
        )
        
        let result = try? safeAccess(sessionRenewRequest) {
            session_renew(oldSession.handle, $0, tokensRefreshedCallback, &sessionHandle)
        }.asStatus

        guard result == .ok else { return nil }
        return ProtonApiSession(handle: Int(sessionHandle))
    }

    public func endSession(cancellationTokenSource: CancellationTokenSource) async throws {
        return try await invokeDDKWithoutRequest(
            objectHandle: handle,
            cancellationTokenSource: cancellationTokenSource,
            functionInvocation: session_end
        ) { tcsPtr, emptyArray in
            tcsPtr?.unretainedTaskCompletion(with: Void.self)
                   .setResult(value: ())
        }
    }

    public func registerArmoredLockedUserKey(armoredUserKey: ArmoredUserKey) -> Status {
        let result = try? safeAccess(armoredUserKey) {
            session_register_armored_locked_user_key(handle, $0)
        }
        return Status(result: result)
    }

    public func registerAddressKeys(addressKeyRegistrationRequest: AddressKeyRegistrationRequest) -> Status {
        let result = try? safeAccess(addressKeyRegistrationRequest) {
            session_register_address_keys(handle, $0)
        }
        return Status(result: result)
    }
}
