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
import AuthenticationServices
import PDUIComponents
import ProtonCoreAuthentication
import ProtonCoreLog
import ProtonCoreLogin
import ProtonCoreObservability
import ProtonCoreUIFoundations
import ProtonCoreServices

final class TwoFAWithSecurityKeyViewModel: NSObject, ObservableObject {
    
    enum State {
        case initial
        case configured(authenticationOptions: AuthenticationOptions)
    }
        
    var state: State = .initial
    var presentationAnchor: ASPresentationAnchor
    @Published var isLoading = false
    @Published var finished: LoginStep?
    let errors = ErrorToastModifier.Stream()
    
    private let login: Login
    
    init(login: Login, authenticationOptions: AuthenticationOptions, presentationAnchor: ASPresentationAnchor) {
        self.login = login
        self.state = .configured(authenticationOptions: authenticationOptions)
        self.presentationAnchor = presentationAnchor
    }
    
    func startSignature() {
        errors.send(nil)
        
        guard case let .configured(authenticationOptions) = state else { return }
        
        let controller = makeAuthController(relyingPartyIdentifier: authenticationOptions.relyingPartyIdentifier,
                                            challenge: authenticationOptions.challenge,
                                            allowedCredentials: authenticationOptions.allowedCredentialIds
        )
        controller.performRequests()
    }
    
    private func makeAuthController(relyingPartyIdentifier: String,
                                    challenge: Data,
                                    allowedCredentials: [Data]) -> ASAuthorizationController {
        let fido2Provider = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
        
        let fido2Request = fido2Provider.createCredentialAssertionRequest(challenge: challenge)
        fido2Request.allowedCredentials = allowedCredentials.map {
            ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(
                credentialID: $0,
                transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported
            )
        }
        
        let passkeyProvider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingPartyIdentifier)
        
        let passkeyRequest = passkeyProvider.createCredentialAssertionRequest(challenge: challenge)
        passkeyRequest.allowedCredentials = allowedCredentials.map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
        }
        
        let controller = ASAuthorizationController(authorizationRequests: [fido2Request, passkeyRequest])
        controller.presentationContextProvider = self
        controller.delegate = self
        return controller
    }
    
    private func provideFido2Signature(_ signature: Fido2Signature) {
        errors.send(nil)
        isLoading = true
        
        login.provideFido2Signature(signature) { [weak self] result in
            
            func showError(_ error: Error) {
                self?.errors.send(error)
                self?.isLoading = false
            }
            
            DispatchQueue.main.async { [weak self] in
                switch result {
                case let .failure(error):
                    switch error {
                    case .invalid2FACode, .invalid2FAKey, .invalidCredentials, .invalidAccessToken:
                        self?.backToStart(error)
                        self?.isLoading = false
                    default:
                        showError(error)
                    }
                case let .success(status):
                    switch status {
                    case let .finished(data):
                        self?.finished = .done(data)
                    case .askSecondPassword:
                        self?.finished = .mailboxPasswordNeeded
                    case .chooseInternalUsernameAndCreateInternalAddress:
                        assertionFailure("Account has a username but no address")
                        showError(LoginError.invalidState)
                    case .askTOTP:
                        assertionFailure("Asking for 2FA code password after successful FIDO is an invalid state")
                        showError(LoginError.invalidState)
                    case .askAny2FA, .askFIDO2:
                        assertionFailure("Asking for FIDO after successful FIDO is an invalid state")
                        showError(LoginError.invalidState)
                    case .ssoChallenge:
                        assertionFailure("receiving an SSO Challenge after successful 2FA code is an invalid state")
                        showError(LoginError.invalidState)
                    @unknown default:
                        assertionFailure("Not implemented")
                        showError(LoginError.invalidState)
                    }
                }
            }
        }
    }
    
    func learnMore() {
        NSWorkspace.shared.open(ExternalLinks.twoFactorAuthentication)
    }
    
    private func backToStart(_ initialError: LoginError) {
        finished = .backToStart(initialError: initialError)
    }
}

extension TwoFAWithSecurityKeyViewModel: ASAuthorizationControllerDelegate {
    
    struct Fido2AuthorizationError: LocalizedError {
        let title: String
        var errorDescription: String { title }
    }
    
    @MainActor
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        switch authorization.credential {
        case let credentialAssertion as ASAuthorizationSecurityKeyPublicKeyCredentialAssertion:
            if case .configured(let authenticationOptions) = state {
                ObservabilityEnv.report(.webAuthnRequestTotal(status: .authorizedFIDO2))
                provideFido2Signature(Fido2Signature(credentialAssertion: credentialAssertion, authenticationOptions: authenticationOptions))
            } else {
                ObservabilityEnv.report(.webAuthnRequestTotal(status: .authorizedMissingChallenge))
                errors.send(Fido2AuthorizationError(title: "Unexpected FIDO2 signature."))
            }
        case let credentialAssertion as ASAuthorizationPlatformPublicKeyCredentialAssertion:
            if case .configured(let authenticationOptions) = state {
                ObservabilityEnv.report(.webAuthnRequestTotal(status: .authorizedPasskey))
                provideFido2Signature(Fido2Signature(credentialAssertion: credentialAssertion, authenticationOptions: authenticationOptions))
            } else {
                ObservabilityEnv.report(.webAuthnRequestTotal(status: .authorizedMissingChallenge))
                errors.send(Fido2AuthorizationError(title: "Unexpected FIDO2 signature."))
            }
        default:
            ObservabilityEnv.report(.webAuthnRequestTotal(status: .authorizedUnsupportedType))
            errors.send(Fido2AuthorizationError(title: "We received an authorization from a type we don't support yet."))
        }
    }
    
    @MainActor
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard let authorizationError = error as? ASAuthorizationError else {
            ObservabilityEnv.report(.webAuthnRequestTotal(status: .errorOther))
            errors.send(Fido2AuthorizationError(title: "Operation couldn't be completed. Please try again."))
            return
        }
        let status: WebAuthnRequestStatus = switch authorizationError.code {
        case .canceled: .errorCanceled
        case .failed: .errorFailed
        case .invalidResponse: .errorInvalidResponse
        case .notHandled: .errorNotHandled
        case .notInteractive: .errorNotInteractive
        case .unknown: .errorUnknown
        @unknown default: .errorOther
        }
        if status != .errorCanceled {
            errors.send(Fido2AuthorizationError(title: "Operation couldn't be completed. Please try again."))
        }
        ObservabilityEnv.report(.webAuthnRequestTotal(status: status))
    }
}

extension TwoFAWithSecurityKeyViewModel: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        presentationAnchor
    }
}

extension Fido2Signature {
    init(credentialAssertion: ASAuthorizationPublicKeyCredentialAssertion, authenticationOptions: AuthenticationOptions) {
        self = .init(signature: credentialAssertion.signature,
                     credentialID: credentialAssertion.credentialID,
                     authenticatorData: credentialAssertion.rawAuthenticatorData,
                     clientData: credentialAssertion.rawClientDataJSON,
                     authenticationOptions: authenticationOptions)
    }
}
