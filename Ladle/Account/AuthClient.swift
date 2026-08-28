import Foundation

@MainActor
final class AuthClient {
    private struct GuestRequest: Encodable, Sendable {
        let installationID: String
        let attestation: AppAttestEvidence?
    }

    private struct AppleRequest: Encodable, Sendable {
        let identityToken: String
        let authorizationCode: String
        let nonce: String
        let idempotencyKey: String
    }

    private struct GoogleRequest: Encodable, Sendable {
        let identityToken: String
        let idempotencyKey: String
    }

    private struct AccountDeletionRequest: Encodable, Sendable {
        let confirmation: String
        let refreshToken: String
        let idempotencyKey: String
    }

    private let api: APIClient
    private let tokenStore: any AuthTokenStoring
    private let accountSession: AccountSession
    private let installationIdentity: InstallationIdentity
    private let appAttester: (any AppAttesting)?

    init(
        api: APIClient,
        tokenStore: any AuthTokenStoring,
        accountSession: AccountSession,
        installationIdentity: InstallationIdentity,
        appAttester: (any AppAttesting)? = nil
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.accountSession = accountSession
        self.installationIdentity = installationIdentity
        self.appAttester = appAttester
    }

    func bootstrapGuest(
        attestation: AppAttestEvidence?,
        applyAccountState: Bool = true
    ) async throws -> AuthTokens {
        let evidence = if let attestation {
            attestation
        } else {
            try await appAttester?.guestEvidence()
        }
        let tokens: AuthTokens = try await api.request(
            path: "/v1/auth/guest",
            method: .post,
            body: GuestRequest(
                installationID: installationIdentity.current,
                attestation: evidence
            ),
            authenticated: false
        )
        try tokenStore.save(tokens)
        if applyAccountState {
            accountSession.applyRemoteUserKind(tokens.userKind)
        }
        return tokens
    }

    func restoreSession() throws -> AuthTokens? {
        let tokens = try tokenStore.load()
        if let tokens {
            accountSession.applyRemoteUserKind(tokens.userKind)
        }
        return tokens
    }

    func signOut() async {
        let signedOutKind = ((try? tokenStore.load()) ?? nil)?.userKind
        // Best-effort server revoke; local sign-out proceeds regardless.
        try? await api.requestWithoutResponse(
            path: "/v1/auth/session",
            method: .delete
        )
        try? tokenStore.clear()
        // The server binds the installation ID to a real account, so carrying
        // it into the next session would hand that account to whoever uses
        // this device next. A guest keeps its identifier: the binding is the
        // only credential a guest library has.
        if let signedOutKind, signedOutKind != "guest" {
            installationIdentity.rotate()
            try? await appAttester?.reset()
        }
        accountSession.signOut()
    }

    func deleteAccount() async throws {
        guard
            let tokens = try tokenStore.load(),
            let refreshToken = tokens.refreshToken
        else {
            throw APIError.refreshUnavailable
        }
        try await api.requestWithoutResponse(
            path: "/v1/auth/account",
            method: .delete,
            body: AccountDeletionRequest(
                confirmation: "DELETE",
                refreshToken: refreshToken,
                idempotencyKey:
                    "delete-\(tokens.userID.uuidString.lowercased())"
            )
        )
        try? tokenStore.clear()
        installationIdentity.rotate()
        try? await appAttester?.reset()
        accountSession.signOut()
    }

    func signInWithApple(
        identityToken: String,
        authorizationCode: String,
        nonce: String,
        idempotencyKey: String
    ) async throws -> AuthTokens {
        let tokens: AuthTokens = try await api.request(
            path: "/v1/auth/apple",
            method: .post,
            body: AppleRequest(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: nonce,
                idempotencyKey: idempotencyKey
            ),
            authenticated: true
        )
        try tokenStore.save(tokens)
        accountSession.applyRemoteUserKind(tokens.userKind)
        return tokens
    }

    func signInWithGoogle(
        identityToken: String,
        idempotencyKey: String
    ) async throws -> AuthTokens {
        let tokens: AuthTokens = try await api.request(
            path: "/v1/auth/google",
            method: .post,
            body: GoogleRequest(
                identityToken: identityToken,
                idempotencyKey: idempotencyKey
            ),
            authenticated: true
        )
        try tokenStore.save(tokens)
        accountSession.applyRemoteUserKind(tokens.userKind)
        return tokens
    }
}
