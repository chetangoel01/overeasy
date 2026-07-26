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

    private static func tokensJSON(accessToken: String) -> Data {
        json([
            "accessToken": accessToken,
            "accessTokenExpiresAt": "2026-07-23T21:15:00.000Z",
            "refreshToken": "rotated-refresh",
            "userID": "10000000-0000-4000-8000-000000000001",
            "deviceID": "10000000-0000-4000-8000-000000000002",
            "userKind": "guest",
        ])
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
        userKind: String = "guest"
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
            userKind: userKind
        )
    }
}
