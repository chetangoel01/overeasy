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
        let tokens = AuthTokens.fixture(accessToken: "stored-access")

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
            accountSession: account
        )

        let guest = try await auth.bootstrapGuest(
            installationID: "ios-installation",
            attestation: nil
        )
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
            accountSession: account
        )

        _ = try await auth.bootstrapGuest(
            installationID: "ios-installation",
            attestation: nil
        )
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
            appAttester: GuestEvidenceAppAttester()
        )

        _ = try await auth.bootstrapGuest(
            installationID: "ios-installation",
            attestation: nil
        )

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
            accountSession: account
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
            accountSession: account
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
        userKind: String
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "accessToken": accessToken,
            "accessTokenExpiresAt": "2026-07-23T21:15:00.000Z",
            "refreshToken": "\(accessToken)-refresh",
            "userID": "10000000-0000-4000-8000-000000000001",
            "deviceID": "10000000-0000-4000-8000-000000000002",
            "userKind": userKind,
        ])
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
