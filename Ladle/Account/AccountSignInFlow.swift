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
                // The shared sentence, not a fourth copy of it.
                report.failure.message
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

    /// Whether sending the very same request again could plausibly work.
    ///
    /// A 503 or a 500 is ours and may well be gone a second later. A refused
    /// identity claim would be refused identically, a build without Google
    /// configured will not gain it, and a provider-side failure never got as
    /// far as a request to repeat.
    var canRetry: Bool {
        switch self {
        case let .remote(report):
            report.failure.canRetry()
        case .missingConfiguration, .identityConflict, .other:
            false
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

    /// The backend exchange the last attempt failed on, kept so Retry can
    /// send that exact request again. Cleared the moment one succeeds.
    private var failedAttempt: Attempt?

    /// One attempt's trip to the backend — and nothing it did through
    /// Apple's or Google's own sheet, which a cook has already answered and
    /// must not be asked to answer twice because our server returned a 500.
    private struct Attempt {
        typealias Exchange = @MainActor () async throws -> Void

        let fallback: String
        let exchange: Exchange
    }

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
                nonce: nonce,
                fullName: Self.displayName(from: credential.fullName)
            )
        }
    }

    /// Apple's name as something that can be stored and shown.
    ///
    /// `credential.fullName` is `PersonNameComponents`, and it is non-nil
    /// only on the very first authorization for an Apple ID — on every later
    /// sign-in the components come back empty, which is nil here rather than
    /// a blank name that would overwrite a real one.
    ///
    /// The result is clamped to what the server accepts: `fullName` is
    /// bounded at 64 characters there, and an over-long name would fail the
    /// whole sign-in rather than arrive shortened.
    static func displayName(from components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let formatted = formatter
            .string(from: components)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formatted.isEmpty else { return nil }
        return String(formatted.prefix(AccountProfile.displayNameLimit))
    }

    func signInWithApple(
        identityToken: String,
        authorizationCode: String,
        nonce: String,
        fullName: String? = nil
    ) async {
        // Outside the exchange, so a retry re-sends the key the failed
        // attempt used — which is what an idempotency key is for after a 500.
        let idempotencyKey = UUID().uuidString.lowercased()
        await run(fallback: Self.appleFallback) { [self] in
            { [self] in
                guard let authClient else {
                    accountSession.signInWithApple()
                    return
                }
                try await ensureRemoteSession(authClient)
                _ = try await authClient.signInWithApple(
                    identityToken: identityToken,
                    authorizationCode: authorizationCode,
                    nonce: nonce,
                    idempotencyKey: idempotencyKey,
                    fullName: fullName
                )
            }
        }
    }

    func signInWithGoogle() async {
        let idempotencyKey = UUID().uuidString.lowercased()
        await run(
            fallback:
                "Sign in with Google didn’t complete. Please try again."
        ) { [self] in
            guard let googleSignIn, let authClient else {
                return { [self] in accountSession.signInWithGoogle() }
            }
            // Google's own sheet, answered once. It is deliberately outside
            // the returned exchange: Retry must not re-present it.
            let identityToken = try await googleSignIn.signIn()
            return { [self] in
                try await ensureRemoteSession(authClient)
                _ = try await authClient.signInWithGoogle(
                    identityToken: identityToken,
                    idempotencyKey: idempotencyKey
                )
            }
        }
    }

    func continueAsGuest() async {
        await run(
            fallback: "Account setup didn’t complete. Please try again."
        ) { [self] in
            { [self] in
                guard let authClient else {
                    accountSession.continueAsGuest()
                    return
                }
                _ = try await authClient.bootstrapGuest(attestation: nil)
            }
        }
    }

    /// Whether the screen should offer to send the failed request again.
    var canRetry: Bool {
        failedAttempt != nil && failure?.canRetry == true
    }

    /// Send the request that failed, again.
    ///
    /// The provider ceremony is not repeated — only the exchange with our
    /// own backend, which is the part that returned the 5xx.
    func retry() async {
        guard let attempt = failedAttempt else { return }
        await run(fallback: attempt.fallback) { attempt.exchange }
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

    /// One attempt, start to finish.
    ///
    /// `prepare` does whatever cannot be replayed — presenting Google's
    /// sheet — and hands back the exchange with our backend. Only that
    /// exchange is remembered, so a failure inside `prepare` leaves nothing
    /// to retry, which is correct: a cancelled sheet never sent a request.
    private func run(
        fallback: String,
        prepare: @MainActor () async throws -> Attempt.Exchange
    ) async {
        guard !isAuthenticating else {
            return
        }
        isAuthenticating = true
        failure = nil
        failedAttempt = nil
        defer { isAuthenticating = false }
        do {
            let exchange = try await prepare()
            failedAttempt = Attempt(fallback: fallback, exchange: exchange)
            try await exchange()
            failedAttempt = nil
            await onAuthenticated()
        } catch {
            failure = AccountAuthenticationFailure(
                error,
                fallback: fallback
            )
            if failure == nil {
                // A cancel is not a failure, so there is nothing to offer.
                failedAttempt = nil
            }
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
