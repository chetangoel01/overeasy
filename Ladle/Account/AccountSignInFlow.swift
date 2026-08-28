import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security

enum AccountAuthenticationFailure: Equatable {
    case missingConfiguration
    case identityConflict
    case remote(RemoteFailureReport)
    case other(String)

    init?(_ error: any Error, fallback: String) {
        if error is CancellationError {
            return nil
        }
        if let googleError = error as? GoogleSignInProviderError {
            switch googleError {
            case .cancelled:
                return nil
            case .missingConfiguration:
                self = .missingConfiguration
                return
            case .missingPresenter, .missingIdentityToken:
                break
            }
        }
        if (error as? ASAuthorizationError)?.code == .canceled {
            return nil
        }
        if case let APIError.remote(remote) = error,
           remote.code == .conflict {
            self = .identityConflict
            return
        }
        if error is APIError {
            self = .remote(RemoteFailureReport(error))
        } else {
            self = .other(fallback)
        }
    }

    var message: String {
        switch self {
        case .missingConfiguration:
            "Google sign-in isn’t configured for this build."
        case .identityConflict:
            "That sign-in couldn’t be linked to these recipes. Try again, or use the other sign-in option."
        case let .remote(report):
            switch report.failure {
            case .offline:
                "You’re offline. Reconnect and try again."
            case .serviceUnavailable:
                "Overeasy is temporarily unavailable. Try again in a moment."
            case let .rateLimited(retryAt):
                "Too many attempts. Try again after \(retryAt.formatted(date: .omitted, time: .shortened))."
            case .quotaExceeded:
                "Account setup has reached its current limit. Try again later."
            case .authenticationExpired:
                "That sign-in session expired. Start sign-in again."
            case .invalidResponse:
                "Overeasy couldn’t read the sign-in response. Try again."
            case .unknown:
                "Account setup didn’t complete. Please try again."
            }
        case let .other(message):
            message
        }
    }
}

/// One sign-in attempt pipeline, shared by the welcome screen and the
/// guest-limit sheet.
///
/// Local `AccountSession` state only changes when the backend confirms it: a
/// successful provider sign-in ends in `AuthClient` persisting the returned
/// tokens and applying the server's user kind. A cancelled, failed, or
/// offline attempt changes nothing, so a guest stays a guest — and stays
/// capped. Builds without an `AuthClient` (demo and UI-test configurations)
/// fall back to flipping the local state directly, as the welcome screen
/// always has.
@MainActor
@Observable
final class AccountSignInFlow {
    private let accountSession: AccountSession
    private let authClient: AuthClient?
    private let googleSignIn: (any GoogleSignInProviding)?
    private let onAuthenticated: @MainActor () async -> Void

    private(set) var isAuthenticating = false
    private(set) var failure: AccountAuthenticationFailure?
    private var rawNonce: String?

    init(
        accountSession: AccountSession,
        authClient: AuthClient?,
        googleSignIn: (any GoogleSignInProviding)?,
        onAuthenticated: @escaping @MainActor () async -> Void
    ) {
        self.accountSession = accountSession
        self.authClient = authClient
        self.googleSignIn = googleSignIn
        self.onAuthenticated = onAuthenticated
    }

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        failure = nil
        let nonce = Self.randomNonce()
        rawNonce = nonce
        request.requestedScopes = [.email, .fullName]
        request.nonce = Self.sha256(nonce)
    }

    func handleAppleCompletion(
        _ result: Result<ASAuthorization, any Error>
    ) async {
        guard !isAuthenticating else {
            return
        }
        switch result {
        case let .failure(error):
            failure = AccountAuthenticationFailure(
                error,
                fallback: Self.appleFallback
            )
        case let .success(authorization):
            guard
                let credential =
                    authorization.credential
                    as? ASAuthorizationAppleIDCredential,
                let identityData = credential.identityToken,
                let identityToken = String(
                    data: identityData,
                    encoding: .utf8
                ),
                let codeData = credential.authorizationCode,
                let authorizationCode = String(
                    data: codeData,
                    encoding: .utf8
                ),
                let nonce = rawNonce
            else {
                failure = .other(
                    "Apple didn’t return a complete credential. Please try again."
                )
                return
            }
            await signInWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: nonce
            )
        }
    }

    func signInWithApple(
        identityToken: String,
        authorizationCode: String,
        nonce: String
    ) async {
        await run(fallback: Self.appleFallback) { [self] in
            guard let authClient else {
                accountSession.signInWithApple()
                return
            }
            try await ensureRemoteSession(authClient)
            _ = try await authClient.signInWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: nonce,
                idempotencyKey: UUID().uuidString.lowercased()
            )
        }
    }

    func signInWithGoogle() async {
        await run(
            fallback:
                "Sign in with Google didn’t complete. Please try again."
        ) { [self] in
            guard let googleSignIn, let authClient else {
                accountSession.signInWithGoogle()
                return
            }
            let identityToken = try await googleSignIn.signIn()
            try await ensureRemoteSession(authClient)
            _ = try await authClient.signInWithGoogle(
                identityToken: identityToken,
                idempotencyKey: UUID().uuidString.lowercased()
            )
        }
    }

    func continueAsGuest() async {
        await run(
            fallback: "Account setup didn’t complete. Please try again."
        ) { [self] in
            guard let authClient else {
                accountSession.continueAsGuest()
                return
            }
            _ = try await authClient.bootstrapGuest(attestation: nil)
        }
    }

    /// An Apple or Google merge claims the caller's current guest user, so
    /// a device without stored tokens registers one first — without touching
    /// local account state until the provider sign-in confirms.
    private func ensureRemoteSession(_ authClient: AuthClient) async throws {
        if try authClient.restoreSession() == nil {
            _ = try await authClient.bootstrapGuest(
                attestation: nil,
                applyAccountState: false
            )
        }
    }

    private func run(
        fallback: String,
        _ authenticate: @MainActor () async throws -> Void
    ) async {
        guard !isAuthenticating else {
            return
        }
        isAuthenticating = true
        failure = nil
        defer { isAuthenticating = false }
        do {
            try await authenticate()
            await onAuthenticated()
        } catch {
            failure = AccountAuthenticationFailure(
                error,
                fallback: fallback
            )
        }
    }

    private static let appleFallback =
        "Sign in with Apple didn’t complete. Please try again."

    private static func randomNonce(length: Int = 32) -> String {
        let alphabet = Array(
            "0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._"
        )
        var result = ""
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        ) == errSecSuccess else {
            return UUID().uuidString
        }
        for byte in bytes {
            result.append(alphabet[Int(byte) % alphabet.count])
        }
        return result
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
