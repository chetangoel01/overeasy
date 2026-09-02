import Foundation
import LadleCore
import XCTest
@testable import Ladle

final class APIClientTests: XCTestCase {
    struct RequestBody: Encodable, Sendable {
        let value: String
    }

    struct ResponseBody: Decodable, Equatable, Sendable {
        let value: String
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testAuthenticatedRequestAddsBearerAndRequestID() async throws {
        let store = InMemoryAuthTokenStore(
            tokens: .fixture(accessToken: "guest-access")
        )
        let captured = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            captured.withValue { $0.append(request) }
            return (
                Self.response(request, status: 200),
                Self.json(["value": "ok"])
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: store
        )

        let value: ResponseBody = try await client.request(
            path: "/v1/test",
            method: .post,
            body: RequestBody(value: "hello"),
            authenticated: true
        )

        XCTAssertEqual(value, ResponseBody(value: "ok"))
        let request = try XCTUnwrap(captured.snapshot.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer guest-access"
        )
        XCTAssertNotNil(
            UUID(uuidString: try XCTUnwrap(
                request.value(forHTTPHeaderField: "X-Request-ID")
            ))
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/test")
    }

    func testTunnelRequestAddsAccessKeyWithoutReplacingBearer() async throws {
        let store = InMemoryAuthTokenStore(
            tokens: .fixture(accessToken: "guest-access")
        )
        let captured = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            captured.withValue { $0.append(request) }
            return (
                Self.response(request, status: 200),
                Self.json(["value": "ok"])
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://example.ngrok.app")!,
            session: URLProtocolStub.session(),
            tokenStore: store,
            tunnelAccessKey: "device-tunnel"
        )

        let _: ResponseBody = try await client.request(
            path: "/v1/test",
            authenticated: true
        )

        let request = try XCTUnwrap(captured.snapshot.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Ladle-Tunnel-Key"),
            "device-tunnel"
        )
        XCTAssertEqual(
            request.value(
                forHTTPHeaderField: "ngrok-skip-browser-warning"
            ),
            "true"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer guest-access"
        )
    }

    func testSensitiveRequestCarriesFreshAppAttestAssertionHeaders() async throws {
        let store = InMemoryAuthTokenStore(
            tokens: .fixture(accessToken: "guest-access")
        )
        let captured = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            captured.withValue { $0.append(request) }
            return (
                Self.response(request, status: 200),
                Self.json(["value": "ok"])
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: store,
            appAttester: StubAppAttester()
        )

        let _: ResponseBody = try await client.request(
            path: "/v1/imports",
            method: .post,
            body: RequestBody(value: "bound-body"),
            appAttestPurpose: .importSubmission
        )

        let request = try XCTUnwrap(captured.snapshot.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-App-Attest-Kind"),
            "assertion"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-App-Attest-Challenge-ID"),
            "10000000-0000-4000-8000-000000000099"
        )
    }

    func testUnauthorizedRequestRefreshesOnceAndReplays() async throws {
        let store = InMemoryAuthTokenStore(
            tokens: .fixture(
                accessToken: "old-access",
                refreshToken: "refresh-token"
            )
        )
        let paths = Locked<[String]>([])
        URLProtocolStub.install { request in
            paths.withValue { $0.append(request.url?.path ?? "") }
            if request.url?.path == "/v1/auth/refresh" {
                return (
                    Self.response(request, status: 200),
                    Self.tokensJSON(accessToken: "new-access")
                )
            }
            if request.value(forHTTPHeaderField: "Authorization")
                == "Bearer old-access"
            {
                return (Self.response(request, status: 401), Data())
            }
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer new-access"
            )
            return (
                Self.response(request, status: 200),
                Self.json(["value": "replayed"])
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: store
        )

        let value: ResponseBody = try await client.request(
            path: "/v1/protected",
            authenticated: true
        )

        XCTAssertEqual(value.value, "replayed")
        XCTAssertEqual(
            paths.snapshot,
            ["/v1/protected", "/v1/auth/refresh", "/v1/protected"]
        )
        XCTAssertEqual(try store.load()?.accessToken, "new-access")
    }

    /// The profile rides on the tokens, so a refresh is also how a name
    /// edited on another device reaches this one — but only if the refreshed
    /// tokens are handed back to whoever holds the session.
    func testRefreshReportsTheProfileItReturns() async throws {
        let store = InMemoryAuthTokenStore(
            tokens: .fixture(
                accessToken: "old-access",
                refreshToken: "refresh-token"
            )
        )
        URLProtocolStub.install { request in
            if request.url?.path == "/v1/auth/refresh" {
                return (
                    Self.response(request, status: 200),
                    Self.tokensJSON(
                        accessToken: "new-access",
                        profile: [
                            "displayName": "Priya Raman",
                            "avatarURL": "https://cdn.test/priya.jpg",
                        ]
                    )
                )
            }
            if request.value(forHTTPHeaderField: "Authorization")
                == "Bearer old-access"
            {
                return (Self.response(request, status: 401), Data())
            }
            return (
                Self.response(request, status: 200),
                Self.json(["value": "replayed"])
            )
        }
        let refreshed = Locked<AuthTokens?>(nil)
        let client = APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: store,
            sessionRefreshed: { tokens in
                refreshed.withValue { $0 = tokens }
            }
        )

        let _: ResponseBody = try await client.request(
            path: "/v1/protected",
            authenticated: true
        )

        XCTAssertEqual(refreshed.snapshot?.displayName, "Priya Raman")
        XCTAssertEqual(
            refreshed.snapshot?.avatarURL,
            URL(string: "https://cdn.test/priya.jpg")
        )
        XCTAssertEqual(try store.load()?.displayName, "Priya Raman")
    }

    func testRejectedRefreshClearsSessionAndReportsExpiry() async throws {
        let store = InMemoryAuthTokenStore(
            tokens: .fixture(
                accessToken: "expired-access",
                refreshToken: "expired-refresh"
            )
        )
        let didExpire = Locked(false)
        URLProtocolStub.install { request in
            (Self.response(request, status: 401), Data())
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: store,
            authenticationExpired: {
                didExpire.withValue { $0 = true }
            }
        )

        do {
            let _: ResponseBody = try await client.request(
                path: "/v1/protected"
            )
            XCTFail("Expected authentication expiry")
        } catch {
            XCTAssertEqual(error as? APIError, .authenticationExpired)
        }

        XCTAssertNil(try store.load())
        XCTAssertTrue(didExpire.snapshot)
    }

    func testConcurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let store = InMemoryAuthTokenStore(
            tokens: .fixture(
                accessToken: "old-access",
                refreshToken: "refresh-token"
            )
        )
        let refreshCount = Locked(0)
        URLProtocolStub.install { request in
            if request.url?.path == "/v1/auth/refresh" {
                refreshCount.withValue { $0 += 1 }
                Thread.sleep(forTimeInterval: 0.05)
                return (
                    Self.response(request, status: 200),
                    Self.tokensJSON(accessToken: "new-access")
                )
            }
            if request.value(forHTTPHeaderField: "Authorization")
                == "Bearer old-access"
            {
                return (Self.response(request, status: 401), Data())
            }
            return (
                Self.response(request, status: 200),
                Self.json(["value": "ok"])
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: store
        )

        let values = try await withThrowingTaskGroup(
            of: ResponseBody.self
        ) { group in
            for index in 0 ..< 5 {
                group.addTask {
                    try await client.request(
                        path: "/v1/protected/\(index)",
                        authenticated: true
                    )
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(values.count, 5)
        XCTAssertEqual(refreshCount.snapshot, 1)
    }

    func testTypedRemoteErrorIsDecoded() async throws {
        URLProtocolStub.install { request in
            (
                Self.response(request, status: 409),
                Self.json([
                    "error": [
                        "code": "duplicateRecipe",
                        "message": "Already saved.",
                        "retryable": false,
                        "requestID": "30000000-0000-4000-8000-000000000001",
                        "details": [
                            "existingRecipeID":
                                "20000000-0000-4000-8000-000000000001"
                        ],
                    ],
                ])
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: InMemoryAuthTokenStore()
        )

        do {
            let _: ResponseBody = try await client.request(
                path: "/v1/test",
                authenticated: false
            )
            XCTFail("Expected remote error")
        } catch let APIError.remote(error) {
            XCTAssertEqual(error.code, .duplicateRecipe)
            XCTAssertEqual(
                error.details,
                .duplicate(
                    existingRecipeID: UUID(
                        uuidString: "20000000-0000-4000-8000-000000000001"
                    )!
                )
            )
        }
    }

    func testCancelledRequestThrowsCancellationInsteadOfTransport() async {
        // Cancelling the awaiting task makes URLSession fail the request
        // with URLError(.cancelled). That must surface as cooperative
        // cancellation, not as the offline transport failure. (#33)
        URLProtocolStub.install { _ in
            throw URLError(.cancelled)
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: InMemoryAuthTokenStore()
        )

        do {
            let _: ResponseBody = try await client.request(
                path: "/v1/recipes/discover",
                authenticated: false
            )
            XCTFail("Expected the cancelled request to throw")
        } catch is CancellationError {
            // Downstream `catch is CancellationError` branches rely on this.
        } catch {
            XCTFail(
                "Cancellation was reported as \(error), which renders as "
                    + "\(RemoteFailure(error)) instead of being ignored"
            )
        }
    }

    func testGenuineTransportFailureStillMapsToTransport() async {
        URLProtocolStub.install { _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: InMemoryAuthTokenStore()
        )

        do {
            let _: ResponseBody = try await client.request(
                path: "/v1/recipes/discover",
                authenticated: false
            )
            XCTFail("Expected the offline request to throw")
        } catch APIError.transport {
            // Real connectivity loss keeps reading as offline.
        } catch {
            XCTFail("Expected APIError.transport, got \(error)")
        }
    }

    private static func response(
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

    private static func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    private static func tokensJSON(
        accessToken: String,
        profile: [String: String] = [:]
    ) -> Data {
        var payload: [String: Any] = [
            "accessToken": accessToken,
            "accessTokenExpiresAt": "2026-07-23T21:15:00.000Z",
            "refreshToken": "rotated-refresh",
            "userID": "10000000-0000-4000-8000-000000000001",
            "deviceID": "10000000-0000-4000-8000-000000000002",
            "userKind": "guest",
        ]
        payload.merge(profile) { _, updated in updated }
        return json(payload)
    }
}

private actor StubAppAttester: AppAttesting {
    func guestEvidence() async throws -> AppAttestEvidence? {
        nil
    }

    func authorize(
        _ request: URLRequest,
        purpose: AppAttestPurpose
    ) async throws -> URLRequest {
        XCTAssertEqual(purpose, .importSubmission)
        var authorized = request
        authorized.setValue(
            "assertion",
            forHTTPHeaderField: "X-App-Attest-Kind"
        )
        authorized.setValue(
            "10000000-0000-4000-8000-000000000099",
            forHTTPHeaderField: "X-App-Attest-Challenge-ID"
        )
        return authorized
    }

    func reset() async throws {}
}

final class InMemoryAuthTokenStore: AuthTokenStoring, @unchecked Sendable {
    private let values: Locked<AuthTokens?>

    init(tokens: AuthTokens? = nil) {
        values = Locked(tokens)
    }

    func load() throws -> AuthTokens? {
        values.snapshot
    }

    func save(_ tokens: AuthTokens) throws {
        values.withValue { $0 = tokens }
    }

    func clear() throws {
        values.withValue { $0 = nil }
    }
}

extension AuthTokens {
    static func fixture(
        accessToken: String,
        refreshToken: String = "refresh-token",
        userKind: String = "guest",
        displayName: String? = nil,
        avatarURL: URL? = nil
    ) -> AuthTokens {
        AuthTokens(
            accessToken: accessToken,
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            refreshToken: refreshToken,
            userID: UUID(
                uuidString: "10000000-0000-4000-8000-000000000001"
            )!,
            deviceID: UUID(
                uuidString: "10000000-0000-4000-8000-000000000002"
            )!,
            userKind: userKind,
            displayName: displayName,
            avatarURL: avatarURL
        )
    }
}
