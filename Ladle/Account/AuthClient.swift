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
        /// Apple supplies a full name only on the first authorization for an
        /// Apple ID, in the credential and in no token. Nil encodes as an
        /// absent key, so a later sign-in says nothing about the name rather
        /// than saying it is empty.
        let fullName: String?
    }

    private struct ProfileRequest: Encodable, Sendable {
        let displayName: String
    }

    private struct ProfileResponse: Decodable, Sendable {
        let userKind: String
        let displayName: String?
        let avatarURL: URL?
        /// Optional here, though the server always sends it: a build talking
        /// to an API that predates the field would otherwise fail every name
        /// edit on a decode rather than losing one line of the facts.
        let createdAt: Date?
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
            accountSession.applyRemoteAccount(
                kind: tokens.userKind,
                profile: tokens.profile
            )
        }
        return tokens
    }

    func restoreSession() throws -> AuthTokens? {
        let tokens = try tokenStore.load()
        if let tokens {
            accountSession.applyRemoteAccount(
                kind: tokens.userKind,
                profile: tokens.profile
            )
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
        idempotencyKey: String,
        fullName: String? = nil
    ) async throws -> AuthTokens {
        let tokens: AuthTokens = try await api.request(
            path: "/v1/auth/apple",
            method: .post,
            body: AppleRequest(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: nonce,
                idempotencyKey: idempotencyKey,
                fullName: fullName
            ),
            authenticated: true
        )
        try tokenStore.save(tokens)
        accountSession.applyRemoteAccount(
            kind: tokens.userKind,
            profile: tokens.profile
        )
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
        accountSession.applyRemoteAccount(
            kind: tokens.userKind,
            profile: tokens.profile
        )
        return tokens
    }

    /// Set the cook's display name. A blank name clears it back to whatever
    /// the provider supplied, which is why it is sent as typed rather than
    /// refused here.
    ///
    /// The stored tokens carry the profile, so they are rewritten with the
    /// server's answer: a relaunch reads the Keychain, not the server, and
    /// would otherwise show the old name until the next refresh.
    func updateProfile(displayName: String) async throws {
        let response: ProfileResponse = try await api.request(
            path: "/v1/auth/profile",
            method: .patch,
            body: ProfileRequest(
                displayName: String(
                    displayName.prefix(AccountProfile.displayNameLimit)
                )
            ),
            authenticated: true
        )
        let profile = AccountProfile(
            displayName: response.displayName,
            avatarURL: response.avatarURL,
            createdAt: response.createdAt
                ?? accountSession.profile?.createdAt
        )
        if var tokens = try? tokenStore.load() {
            tokens.displayName = profile.displayName
            tokens.avatarURL = profile.avatarURL
            tokens.createdAt = profile.createdAt ?? tokens.createdAt
            try? tokenStore.save(tokens)
        }
        accountSession.applyProfile(profile)
    }
}
