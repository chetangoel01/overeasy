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

    private let api: APIClient
    private let tokenStore: any AuthTokenStoring
    private let accountSession: AccountSession
    private let appAttester: (any AppAttesting)?

    init(
        api: APIClient,
        tokenStore: any AuthTokenStoring,
        accountSession: AccountSession,
        appAttester: (any AppAttesting)? = nil
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.accountSession = accountSession
        self.appAttester = appAttester
    }

    func bootstrapGuest(
        installationID: String,
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
                installationID: installationID,
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
        // Best-effort server revoke; local sign-out proceeds regardless.
        try? await api.requestWithoutResponse(
            path: "/v1/auth/session",
            method: .delete
        )
        try? tokenStore.clear()
        accountSession.signOut()
    }

    func deleteAccount() async throws {
        try await api.requestWithoutResponse(
            path: "/v1/auth/account",
            method: .delete
        )
        try? tokenStore.clear()
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
