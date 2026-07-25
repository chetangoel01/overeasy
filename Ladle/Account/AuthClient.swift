import Foundation

@MainActor
final class AuthClient {
    private struct GuestRequest: Encodable, Sendable {
        let installationID: String
        let attestation: String?
    }

    private struct AppleRequest: Encodable, Sendable {
        let identityToken: String
        let authorizationCode: String
        let nonce: String
        let idempotencyKey: String
    }

    private let api: APIClient
    private let tokenStore: any AuthTokenStoring
    private let accountSession: AccountSession

    init(
        api: APIClient,
        tokenStore: any AuthTokenStoring,
        accountSession: AccountSession
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.accountSession = accountSession
    }

    func bootstrapGuest(
        installationID: String,
        attestation: String?,
        applyAccountState: Bool = true
    ) async throws -> AuthTokens {
        let tokens: AuthTokens = try await api.request(
            path: "/v1/auth/guest",
            method: .post,
            body: GuestRequest(
                installationID: installationID,
                attestation: attestation
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
}
