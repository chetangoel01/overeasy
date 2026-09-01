import Foundation
import XCTest
@testable import Ladle

@MainActor
final class AuthClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testKeychainTokenStoreRoundTripsThroughInjectedSecureStore() throws {
        let secureStore = InMemorySecureDataStore()
        let tokenStore = KeychainTokenStore(
            service: "com.ladle.tests",
            account: "tokens",
            secureStore: secureStore
        )
        let tokens = AuthTokens.fixture(
            accessToken: "stored-access",
            displayName: "Priya Raman",
            avatarURL: URL(string: "https://cdn.test/priya.jpg")
        )

        try tokenStore.save(tokens)

        XCTAssertEqual(try tokenStore.load(), tokens)
        try tokenStore.clear()
        XCTAssertNil(try tokenStore.load())
    }

    func testGuestBootstrapThenAppleMergePersistsRotatedAccountState() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            if request.url?.path == "/v1/auth/guest" {
                return (
                    Self.response(request, status: 201),
                    Self.tokensJSON(
                        accessToken: "guest-access",
                        userKind: "guest"
                    )
                )
            }
            XCTAssertEqual(request.url?.path, "/v1/auth/apple")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer guest-access"
            )
            return (
                Self.response(request, status: 200),
                Self.tokensJSON(
                    accessToken: "apple-access",
                    userKind: "apple"
                )
            )
        }
        let tokenStore = InMemoryAuthTokenStore()
        let api = APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: tokenStore
        )
        let account = AccountSession(store: InMemoryAuthPreferenceStore())
        let auth = AuthClient(
            api: api,
            tokenStore: tokenStore,
            accountSession: account,
            installationIdentity: InstallationIdentity(
                store: InMemoryAuthPreferenceStore()
            )
        )

        let guest = try await auth.bootstrapGuest(attestation: nil)
        let apple = try await auth.signInWithApple(
            identityToken: "identity-token",
            authorizationCode: "authorization-code",
            nonce: "raw-nonce",
            idempotencyKey: "apple-attempt"
        )

        XCTAssertEqual(guest.userKind, "guest")
        XCTAssertEqual(apple.userKind, "apple")
        XCTAssertEqual(apple.userID, guest.userID)
        XCTAssertEqual(account.state, .signedInWithApple)
        XCTAssertEqual(try tokenStore.load()?.accessToken, "apple-access")
        XCTAssertEqual(requests.snapshot.count, 2)
    }

    func testGuestBootstrapThenGoogleMergePersistsRotatedAccountState() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            if request.url?.path == "/v1/auth/guest" {
                return (
                    Self.response(request, status: 201),
                    Self.tokensJSON(
                        accessToken: "guest-access",
                        userKind: "guest"
                    )
                )
            }
            XCTAssertEqual(request.url?.path, "/v1/auth/google")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer guest-access"
            )
            let body = try JSONSerialization.jsonObject(
                with: URLProtocolStub.bodyData(for: request)
            ) as? [String: Any]
            XCTAssertEqual(body?["identityToken"] as? String, "google-id-token")
            XCTAssertEqual(body?["idempotencyKey"] as? String, "google-attempt")
            return (
                Self.response(request, status: 200),
                Self.tokensJSON(
                    accessToken: "google-access",
                    userKind: "google"
                )
            )
        }
        let tokenStore = InMemoryAuthTokenStore()
        let api = APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: tokenStore
        )
        let account = AccountSession(store: InMemoryAuthPreferenceStore())
        let auth = AuthClient(
            api: api,
            tokenStore: tokenStore,
            accountSession: account,
            installationIdentity: InstallationIdentity(
                store: InMemoryAuthPreferenceStore()
            )
        )

        _ = try await auth.bootstrapGuest(attestation: nil)
        let google = try await auth.signInWithGoogle(
            identityToken: "google-id-token",
            idempotencyKey: "google-attempt"
        )

        XCTAssertEqual(google.userKind, "google")
        XCTAssertEqual(account.state, .signedInWithGoogle)
        XCTAssertEqual(try tokenStore.load()?.accessToken, "google-access")
        XCTAssertEqual(requests.snapshot.count, 2)
    }

    func testGuestBootstrapIncludesDeviceAttestationEvidence() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            return (
                Self.response(request, status: 201),
                Self.tokensJSON(
                    accessToken: "guest-access",
                    userKind: "guest"
                )
            )
        }
        let tokenStore = InMemoryAuthTokenStore()
        let auth = AuthClient(
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: URLProtocolStub.session(),
                tokenStore: tokenStore
            ),
            tokenStore: tokenStore,
            accountSession: AccountSession(
                store: InMemoryAuthPreferenceStore()
            ),
            installationIdentity: InstallationIdentity(
                store: InMemoryAuthPreferenceStore()
            ),
            appAttester: GuestEvidenceAppAttester()
        )

        _ = try await auth.bootstrapGuest(attestation: nil)

        let body = try JSONSerialization.jsonObject(
            with: URLProtocolStub.bodyData(for: requests.snapshot[0])
        ) as? [String: Any]
        let evidence = body?["attestation"] as? [String: Any]
        XCTAssertEqual(evidence?["kind"] as? String, "attestation")
        XCTAssertEqual(evidence?["keyID"] as? String, "device-key")
    }

    func testRestoreAppliesPersistedServerAccountState() throws {
        let tokenStore = InMemoryAuthTokenStore(
            tokens: .fixture(
                accessToken: "restored",
                userKind: "apple"
            )
        )
        let account = AccountSession(store: InMemoryAuthPreferenceStore())
        let auth = AuthClient(
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: URLProtocolStub.session(),
                tokenStore: tokenStore
            ),
            tokenStore: tokenStore,
            accountSession: account,
            installationIdentity: InstallationIdentity(
                store: InMemoryAuthPreferenceStore()
            )
        )

        let restored = try auth.restoreSession()

        XCTAssertEqual(restored?.accessToken, "restored")
        XCTAssertEqual(account.state, .signedInWithApple)
    }

    func testDeleteAccountRemovesServerAndLocalSession() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            return (Self.response(request, status: 204), Data())
        }
        let tokenStore = InMemoryAuthTokenStore(
            tokens: .fixture(accessToken: "delete-access")
        )
        let account = AccountSession(store: InMemoryAuthPreferenceStore())
        account.continueAsGuest()
        let auth = AuthClient(
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: URLProtocolStub.session(),
                tokenStore: tokenStore
            ),
            tokenStore: tokenStore,
            accountSession: account,
            installationIdentity: InstallationIdentity(
                store: InMemoryAuthPreferenceStore()
            )
        )

        try await auth.deleteAccount()

        XCTAssertEqual(requests.snapshot.count, 1)
        XCTAssertEqual(requests.snapshot[0].url?.path, "/v1/auth/account")
        XCTAssertEqual(requests.snapshot[0].httpMethod, "DELETE")
        let body = try URLProtocolStub.bodyData(for: requests.snapshot[0])
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        XCTAssertEqual(json["confirmation"], "DELETE")
        XCTAssertEqual(json["refreshToken"], "refresh-token")
        XCTAssertEqual(
            json["idempotencyKey"],
            "delete-10000000-0000-4000-8000-000000000001"
        )
        XCTAssertEqual(
            requests.snapshot[0].value(
                forHTTPHeaderField: "Authorization"
            ),
            "Bearer delete-access"
        )
        XCTAssertNil(try tokenStore.load())
        XCTAssertEqual(account.state, .undecided)
        XCTAssertTrue(account.shouldPresentWelcome)
    }

    func testDeleteAccountRateLimitPreservesLocalSession() async throws {
        let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
        URLProtocolStub.install { request in
            (
                Self.response(request, status: 429),
                Self.errorJSON(
                    code: "rateLimited",
                    details: [
                        "retryAt": "2027-01-15T08:00:00.000Z",
                    ]
                )
            )
        }
        let tokens = AuthTokens.fixture(accessToken: "delete-access")
        let tokenStore = InMemoryAuthTokenStore(tokens: tokens)
        let account = AccountSession(store: InMemoryAuthPreferenceStore())
        account.applyRemoteAccount(kind: "google")
        let auth = AuthClient(
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: URLProtocolStub.session(),
                tokenStore: tokenStore
            ),
            tokenStore: tokenStore,
            accountSession: account,
            installationIdentity: InstallationIdentity(
                store: InMemoryAuthPreferenceStore()
            )
        )

        do {
            try await auth.deleteAccount()
            XCTFail("Expected deletion rate limit")
        } catch {
            XCTAssertEqual(
                RemoteFailure(error),
                .rateLimited(retryAt: retryAt)
            )
        }
        XCTAssertEqual(try tokenStore.load(), tokens)
        XCTAssertEqual(account.state, .signedInWithGoogle)
        XCTAssertFalse(account.shouldPresentWelcome)
    }

    func testSignOutRotatesTheInstallationIDOfARealAccount() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            if request.url?.path == "/v1/auth/guest" {
                return (
                    Self.response(request, status: 201),
                    Self.tokensJSON(
                        accessToken: "guest-access",
                        userKind: "apple"
                    )
                )
            }
            return (Self.response(request, status: 204), Data())
        }
        let identity = InstallationIdentity(
            store: InMemoryAuthPreferenceStore()
        )
        let attester = RecordingAppAttester()
        let auth = Self.makeAuthClient(
            installationIdentity: identity,
            appAttester: attester
        )

        _ = try await auth.bootstrapGuest(attestation: nil)
        let claimed = Self.installationID(in: requests.snapshot)
        await auth.signOut()
        _ = try await auth.bootstrapGuest(attestation: nil)

        let replayed = Self.installationID(in: requests.snapshot)
        XCTAssertNotNil(claimed)
        XCTAssertNotEqual(claimed, replayed)
        XCTAssertEqual(replayed, identity.current)
        let didReset = await attester.didReset
        XCTAssertTrue(didReset)
    }

    func testSignOutKeepsTheInstallationIDOfAGuest() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            if request.url?.path == "/v1/auth/guest" {
                return (
                    Self.response(request, status: 201),
                    Self.tokensJSON(
                        accessToken: "guest-access",
                        userKind: "guest"
                    )
                )
            }
            return (Self.response(request, status: 204), Data())
        }
        let identity = InstallationIdentity(
            store: InMemoryAuthPreferenceStore()
        )
        let attester = RecordingAppAttester()
        let auth = Self.makeAuthClient(
            installationIdentity: identity,
            appAttester: attester
        )

        _ = try await auth.bootstrapGuest(attestation: nil)
        let created = Self.installationID(in: requests.snapshot)
        await auth.signOut()
        _ = try await auth.bootstrapGuest(attestation: nil)

        XCTAssertNotNil(created)
        XCTAssertEqual(created, Self.installationID(in: requests.snapshot))
        let didReset = await attester.didReset
        XCTAssertFalse(didReset)
    }

    func testTokensCarryTheProfileIntoTheSessionAndKeychain() async throws {
        URLProtocolStub.install { request in
            (
                Self.response(request, status: 201),
                Self.tokensJSON(
                    accessToken: "guest-access",
                    userKind: "google",
                    profile: [
                        "displayName": "Priya Raman",
                        "avatarURL": "https://cdn.test/priya.jpg",
                    ]
                )
            )
        }
        let tokenStore = InMemoryAuthTokenStore()
        let account = AccountSession(store: InMemoryAuthPreferenceStore())
        let auth = AuthClient(
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: URLProtocolStub.session(),
                tokenStore: tokenStore
            ),
            tokenStore: tokenStore,
            accountSession: account,
            installationIdentity: InstallationIdentity(
                store: InMemoryAuthPreferenceStore()
            )
        )

        let tokens = try await auth.bootstrapGuest(attestation: nil)

        XCTAssertEqual(tokens.displayName, "Priya Raman")
        XCTAssertEqual(
            tokens.avatarURL,
            URL(string: "https://cdn.test/priya.jpg")
        )
        XCTAssertEqual(account.profile?.displayName, "Priya Raman")
        XCTAssertEqual(
            try tokenStore.load()?.avatarURL,
            URL(string: "https://cdn.test/priya.jpg")
        )
    }

    /// Tokens written by a build that predates the profile — and any response
    /// from an account that has none — restore as a profile-less session
    /// rather than failing to decode.
    func testTokensWithoutAProfileRestoreWithoutOne() throws {
        let tokenStore = InMemoryAuthTokenStore(
            tokens: .fixture(accessToken: "restored", userKind: "apple")
        )
        let account = AccountSession(store: InMemoryAuthPreferenceStore())
        let auth = AuthClient(
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: URLProtocolStub.session(),
                tokenStore: tokenStore
            ),
            tokenStore: tokenStore,
            accountSession: account,
            installationIdentity: InstallationIdentity(
                store: InMemoryAuthPreferenceStore()
            )
        )

        _ = try auth.restoreSession()

        XCTAssertEqual(account.state, .signedInWithApple)
        XCTAssertNil(account.profile)
    }

    /// Apple returns a full name exactly once, in the credential on the first
    /// authorization. A client that does not forward it loses it for good.
    func testAppleSignInForwardsTheNameAppleSuppliesOnce() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            return (
                Self.response(request, status: 200),
                Self.tokensJSON(
                    accessToken: "apple-access",
                    userKind: "apple",
                    profile: ["displayName": "Priya Raman"]
                )
            )
        }
        let tokenStore = InMemoryAuthTokenStore(
            tokens: .fixture(accessToken: "guest-access")
        )
        let account = AccountSession(store: InMemoryAuthPreferenceStore())
        let auth = AuthClient(
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: URLProtocolStub.session(),
                tokenStore: tokenStore
            ),
            tokenStore: tokenStore,
            accountSession: account,
            installationIdentity: InstallationIdentity(
                store: InMemoryAuthPreferenceStore()
            )
        )

        _ = try await auth.signInWithApple(
            identityToken: "identity-token",
            authorizationCode: "authorization-code",
            nonce: "raw-nonce",
            idempotencyKey: "apple-attempt",
            fullName: "Priya Raman"
        )

        let body = try JSONSerialization.jsonObject(
            with: URLProtocolStub.bodyData(for: requests.snapshot[0])
        ) as? [String: Any]
        XCTAssertEqual(body?["fullName"] as? String, "Priya Raman")
        XCTAssertEqual(account.profile?.displayName, "Priya Raman")
    }

    /// Every Apple sign-in after the first carries no name. The key must be
    /// absent rather than empty, so the server never seeds a blank name.
    func testAppleSignInOmitsAnAbsentName() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            return (
                Self.response(request, status: 200),
                Self.tokensJSON(
                    accessToken: "apple-access",
                    userKind: "apple"
                )
            )
        }
        let tokenStore = InMemoryAuthTokenStore(
            tokens: .fixture(accessToken: "guest-access")
        )
        let auth = AuthClient(
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: URLProtocolStub.session(),
                tokenStore: tokenStore
            ),
            tokenStore: tokenStore,
            accountSession: AccountSession(
                store: InMemoryAuthPreferenceStore()
            ),
            installationIdentity: InstallationIdentity(
                store: InMemoryAuthPreferenceStore()
            )
        )

        _ = try await auth.signInWithApple(
            identityToken: "identity-token",
            authorizationCode: "authorization-code",
            nonce: "raw-nonce",
            idempotencyKey: "apple-attempt"
        )

        let body = try JSONSerialization.jsonObject(
            with: URLProtocolStub.bodyData(for: requests.snapshot[0])
        ) as? [String: Any]
        XCTAssertNil(body?["fullName"])
    }

    func testEditingTheNameSendsAPatchAndUpdatesTheStoredSession() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            return (
                Self.response(request, status: 200),
                Self.profileJSON(displayName: "Priya R.")
            )
        }
        let tokenStore = InMemoryAuthTokenStore(
            tokens: .fixture(
                accessToken: "google-access",
                userKind: "google",
                displayName: "Priya Raman",
                avatarURL: URL(string: "https://cdn.test/priya.jpg")
            )
        )
        let account = AccountSession(store: InMemoryAuthPreferenceStore())
        account.applyRemoteAccount(
            kind: "google",
            profile: AccountProfile(
                displayName: "Priya Raman",
                avatarURL: URL(string: "https://cdn.test/priya.jpg")
            )
        )
        let auth = AuthClient(
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: URLProtocolStub.session(),
                tokenStore: tokenStore
            ),
            tokenStore: tokenStore,
            accountSession: account,
            installationIdentity: InstallationIdentity(
                store: InMemoryAuthPreferenceStore()
            )
        )

        try await auth.updateProfile(displayName: "Priya R.")

        XCTAssertEqual(requests.snapshot.count, 1)
        XCTAssertEqual(requests.snapshot[0].url?.path, "/v1/auth/profile")
        XCTAssertEqual(requests.snapshot[0].httpMethod, "PATCH")
        let body = try JSONSerialization.jsonObject(
            with: URLProtocolStub.bodyData(for: requests.snapshot[0])
        ) as? [String: Any]
        XCTAssertEqual(body?["displayName"] as? String, "Priya R.")
        XCTAssertEqual(account.profile?.displayName, "Priya R.")
        // A relaunch reads the Keychain, not the server, so the edit has to
        // land there too or the old name comes back.
        XCTAssertEqual(try tokenStore.load()?.displayName, "Priya R.")
        XCTAssertEqual(
            try tokenStore.load()?.avatarURL,
            URL(string: "https://cdn.test/priya.jpg"),
            "Editing the name must not drop the avatar"
        )
    }

    private static func makeAuthClient(
        installationIdentity: InstallationIdentity,
        appAttester: (any AppAttesting)? = nil
    ) -> AuthClient {
        let tokenStore = InMemoryAuthTokenStore()
        return AuthClient(
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: URLProtocolStub.session(),
                tokenStore: tokenStore
            ),
            tokenStore: tokenStore,
            accountSession: AccountSession(
                store: InMemoryAuthPreferenceStore()
            ),
            installationIdentity: installationIdentity,
            appAttester: appAttester
        )
    }

    private static func installationID(
        in requests: [URLRequest]
    ) -> String? {
        guard
            let request = requests.last(where: {
                $0.url?.path == "/v1/auth/guest"
            }),
            let body = try? JSONSerialization.jsonObject(
                with: URLProtocolStub.bodyData(for: request)
            ) as? [String: Any]
        else {
            return nil
        }
        return body["installationID"] as? String
    }

    nonisolated private static func response(
        _ request: URLRequest,
        status: Int
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    nonisolated private static func tokensJSON(
        accessToken: String,
        userKind: String,
        profile: [String: String] = [:]
    ) -> Data {
        var payload: [String: Any] = [
            "accessToken": accessToken,
            "accessTokenExpiresAt": "2026-07-23T21:15:00.000Z",
            "refreshToken": "\(accessToken)-refresh",
            "userID": "10000000-0000-4000-8000-000000000001",
            "deviceID": "10000000-0000-4000-8000-000000000002",
            "userKind": userKind,
        ]
        payload.merge(profile) { _, updated in updated }
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    nonisolated private static func profileJSON(
        displayName: String
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "userKind": "google",
            "displayName": displayName,
            "avatarURL": "https://cdn.test/priya.jpg",
        ])
    }

    nonisolated private static func errorJSON(
        code: String,
        details: [String: String]
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "error": [
                "code": code,
                "details": details,
                "message": "Try again later.",
                "requestID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "retryable": true,
            ],
        ])
    }
}

private actor RecordingAppAttester: AppAttesting {
    private(set) var didReset = false

    func guestEvidence() async throws -> AppAttestEvidence? {
        nil
    }

    func authorize(
        _ request: URLRequest,
        purpose: AppAttestPurpose
    ) async throws -> URLRequest {
        request
    }

    func reset() async throws {
        didReset = true
    }
}

private actor GuestEvidenceAppAttester: AppAttesting {
    func guestEvidence() async throws -> AppAttestEvidence? {
        AppAttestEvidence(
            kind: .attestation,
            keyID: "device-key",
            challengeID: UUID(
                uuidString: "10000000-0000-4000-8000-000000000099"
            )!,
            challenge: "Y2hhbGxlbmdl",
            attestationObject: "YXR0ZXN0YXRpb24=",
            assertion: nil,
            clientData: nil
        )
    }

    func authorize(
        _ request: URLRequest,
        purpose: AppAttestPurpose
    ) async throws -> URLRequest {
        request
    }

    func reset() async throws {}
}

private final class InMemorySecureDataStore: SecureDataStoring {
    private var values: [String: Data] = [:]

    func read(service: String, account: String) throws -> Data? {
        values["\(service):\(account)"]
    }

    func write(_ data: Data, service: String, account: String) throws {
        values["\(service):\(account)"] = data
    }

    func delete(service: String, account: String) throws {
        values["\(service):\(account)"] = nil
    }
}

private final class InMemoryAuthPreferenceStore: PreferenceStoring {
    private var values: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}
