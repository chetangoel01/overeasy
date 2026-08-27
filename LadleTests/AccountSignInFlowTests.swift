import AuthenticationServices
import Foundation
import LadleCore
import XCTest
@testable import Ladle

/// The guest-limit sheet and the welcome screen share `AccountSignInFlow`.
/// These tests pin the invariant behind the 10-recipe guest cap: local
/// account state changes only when the backend confirms an account, so a
/// cancelled, failed, offline, or conflicted sign-in leaves the guest
/// capped — and leaves the sheet interactive, never a dead spinner.
@MainActor
final class AccountSignInFlowTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testCancelledGoogleSignInLeavesTheGuestCappedAndInteractive() async {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            return (Self.response(request, status: 500), Data())
        }
        let fixture = makeFixture(
            googleResult: .failure(GoogleSignInProviderError.cancelled)
        )

        await fixture.flow.signInWithGoogle()

        XCTAssertEqual(fixture.accountSession.state, .guest)
        XCTAssertEqual(
            fixture.accountSession.saveDecision(savedRecipeCount: 10),
            .limitReached,
            "A cancelled sign-in must not lift the guest cap"
        )
        XCTAssertNil(
            fixture.flow.failure,
            "A deliberate cancel is not an error to report"
        )
        XCTAssertFalse(
            fixture.flow.isAuthenticating,
            "The sheet must be ready for another attempt"
        )
        XCTAssertEqual(fixture.onAuthenticatedCount(), 0)
        XCTAssertTrue(
            requests.snapshot.isEmpty,
            "A cancelled provider sheet must not reach the backend"
        )
    }

    func testCancelledAppleSignInShowsNoFailureAndKeepsTheCap() async {
        let fixture = makeFixture()

        await fixture.flow.handleAppleCompletion(
            .failure(ASAuthorizationError(.canceled))
        )

        XCTAssertEqual(fixture.accountSession.state, .guest)
        XCTAssertEqual(
            fixture.accountSession.saveDecision(savedRecipeCount: 10),
            .limitReached
        )
        XCTAssertNil(fixture.flow.failure)
        XCTAssertFalse(fixture.flow.isAuthenticating)
        XCTAssertEqual(fixture.onAuthenticatedCount(), 0)
    }

    func testProviderFailureShowsAVisibleMessageAndKeepsTheCap() async {
        let fixture = makeFixture(
            googleResult: .failure(
                GoogleSignInProviderError.missingIdentityToken
            )
        )

        await fixture.flow.signInWithGoogle()

        XCTAssertEqual(fixture.accountSession.state, .guest)
        XCTAssertEqual(
            fixture.accountSession.saveDecision(savedRecipeCount: 10),
            .limitReached
        )
        XCTAssertEqual(
            fixture.flow.failure,
            .other("Sign in with Google didn’t complete. Please try again.")
        )
        XCTAssertEqual(fixture.onAuthenticatedCount(), 0)
    }

    func testOfflineSignInShowsOfflineAndKeepsTheCap() async throws {
        URLProtocolStub.install { _ in
            throw URLError(.notConnectedToInternet)
        }
        let fixture = makeFixture()

        await fixture.flow.signInWithGoogle()

        XCTAssertEqual(fixture.accountSession.state, .guest)
        XCTAssertEqual(
            fixture.accountSession.saveDecision(savedRecipeCount: 10),
            .limitReached,
            "An offline sign-in must not lift the guest cap"
        )
        XCTAssertEqual(
            fixture.flow.failure,
            .remote(RemoteFailureReport(APIError.transport))
        )
        XCTAssertEqual(
            fixture.flow.failure?.message,
            "You’re offline. Reconnect and try again."
        )
        XCTAssertEqual(
            try fixture.tokenStore.load()?.accessToken,
            "guest-access",
            "The guest session must survive the failed attempt"
        )
        XCTAssertEqual(fixture.onAuthenticatedCount(), 0)
    }

    func testIdentityConflictShowsAVisibleMessageAndKeepsTheCap() async {
        URLProtocolStub.install { request in
            (
                Self.response(request, status: 409),
                Self.errorJSON(code: "conflict")
            )
        }
        let fixture = makeFixture()

        await fixture.flow.signInWithGoogle()

        XCTAssertEqual(fixture.accountSession.state, .guest)
        XCTAssertEqual(
            fixture.accountSession.saveDecision(savedRecipeCount: 10),
            .limitReached,
            "A refused identity claim must not lift the guest cap"
        )
        XCTAssertEqual(fixture.flow.failure, .identityConflict)
        XCTAssertFalse(fixture.flow.failure?.message.isEmpty ?? true)
        XCTAssertEqual(fixture.onAuthenticatedCount(), 0)
    }

    func testSecondTapWhileSignInIsInFlightIsIgnored() async {
        URLProtocolStub.install { request in
            (
                Self.response(request, status: 200),
                Self.tokensJSON(
                    accessToken: "google-access",
                    userKind: "google"
                )
            )
        }
        let fixture = makeFixture()
        fixture.googleSignIn.holdsSignIn = true

        let first = Task { await fixture.flow.signInWithGoogle() }
        for _ in 0..<1_000 where !fixture.flow.isAuthenticating {
            await Task.yield()
        }
        XCTAssertTrue(fixture.flow.isAuthenticating)

        await fixture.flow.signInWithGoogle()

        XCTAssertEqual(
            fixture.googleSignIn.signInCallCount,
            1,
            "A second tap while a sign-in is in flight must be ignored"
        )

        fixture.googleSignIn.releaseHeldSignIn()
        await first.value

        XCTAssertEqual(fixture.accountSession.state, .signedInWithGoogle)
        XCTAssertEqual(fixture.onAuthenticatedCount(), 1)
    }

    func testSuccessfulGoogleSignInAppliesTheConfirmedAccount() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            XCTAssertEqual(request.url?.path, "/v1/auth/google")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer guest-access"
            )
            return (
                Self.response(request, status: 200),
                Self.tokensJSON(
                    accessToken: "google-access",
                    userKind: "google",
                    // A different user: the guest merged into the identity's
                    // existing account, which is why the caller re-syncs.
                    userID: "20000000-0000-4000-8000-000000000009"
                )
            )
        }
        let fixture = makeFixture()

        await fixture.flow.signInWithGoogle()

        XCTAssertEqual(requests.snapshot.count, 1)
        XCTAssertEqual(fixture.accountSession.state, .signedInWithGoogle)
        XCTAssertEqual(
            fixture.accountSession.saveDecision(savedRecipeCount: 10),
            .allow,
            "A backend-confirmed account lifts the guest cap"
        )
        XCTAssertEqual(
            try fixture.tokenStore.load()?.accessToken,
            "google-access"
        )
        XCTAssertEqual(fixture.onAuthenticatedCount(), 1)
        XCTAssertNil(fixture.flow.failure)
        XCTAssertFalse(fixture.flow.isAuthenticating)
    }

    func testSignInWithoutStoredTokensBootstrapsAGuestFirst() async {
        // A guest with zero recipes — or a wiped keychain — has no stored
        // session. The claim needs one, registered without touching local
        // account state until the provider sign-in confirms.
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
            return (
                Self.response(request, status: 200),
                Self.tokensJSON(
                    accessToken: "google-access",
                    userKind: "google"
                )
            )
        }
        let fixture = makeFixture(storedTokens: nil)

        await fixture.flow.signInWithGoogle()

        XCTAssertEqual(
            requests.snapshot.map(\.url?.path),
            ["/v1/auth/guest", "/v1/auth/google"]
        )
        XCTAssertEqual(fixture.accountSession.state, .signedInWithGoogle)
        XCTAssertEqual(fixture.onAuthenticatedCount(), 1)
    }

    func testSuccessfulAppleSignInAppliesTheConfirmedAccount() async {
        URLProtocolStub.install { request in
            XCTAssertEqual(request.url?.path, "/v1/auth/apple")
            return (
                Self.response(request, status: 200),
                Self.tokensJSON(
                    accessToken: "apple-access",
                    userKind: "apple"
                )
            )
        }
        let fixture = makeFixture()

        await fixture.flow.signInWithApple(
            identityToken: "identity-token",
            authorizationCode: "authorization-code",
            nonce: "raw-nonce"
        )

        XCTAssertEqual(fixture.accountSession.state, .signedInWithApple)
        XCTAssertEqual(
            fixture.accountSession.saveDecision(savedRecipeCount: 10),
            .allow
        )
        XCTAssertEqual(fixture.onAuthenticatedCount(), 1)
    }

    func testDemoConfigurationWithoutBackendStillUnlocksAfterSignIn() async {
        // Demo and UI-test builds have no AuthClient; the sheet falls back
        // to the local flip the welcome screen has always used there.
        let counter = Locked(0)
        let accountSession = AccountSession(
            store: InMemoryPreferenceStore()
        )
        accountSession.continueAsGuest()
        let flow = AccountSignInFlow(
            accountSession: accountSession,
            authClient: nil,
            googleSignIn: nil,
            onAuthenticated: { counter.withValue { $0 += 1 } }
        )

        await flow.signInWithGoogle()

        XCTAssertEqual(accountSession.state, .signedInWithGoogle)
        XCTAssertEqual(counter.snapshot, 1)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let flow: AccountSignInFlow
        let accountSession: AccountSession
        let tokenStore: InMemoryAuthTokenStore
        let googleSignIn: StubGoogleSignInProvider
        let onAuthenticatedCount: () -> Int
    }

    private func makeFixture(
        storedTokens: AuthTokens? = .fixture(
            accessToken: "guest-access",
            userKind: "guest"
        ),
        googleResult: Result<String, any Error> = .success("google-id-token")
    ) -> Fixture {
        let counter = Locked(0)
        let tokenStore = InMemoryAuthTokenStore(tokens: storedTokens)
        let accountSession = AccountSession(
            store: InMemoryPreferenceStore()
        )
        accountSession.continueAsGuest()
        let authClient = AuthClient(
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: URLProtocolStub.session(),
                tokenStore: tokenStore
            ),
            tokenStore: tokenStore,
            accountSession: accountSession,
            installationIdentity: InstallationIdentity(
                store: InMemoryPreferenceStore()
            )
        )
        let googleSignIn = StubGoogleSignInProvider(result: googleResult)
        return Fixture(
            flow: AccountSignInFlow(
                accountSession: accountSession,
                authClient: authClient,
                googleSignIn: googleSignIn,
                onAuthenticated: { counter.withValue { $0 += 1 } }
            ),
            accountSession: accountSession,
            tokenStore: tokenStore,
            googleSignIn: googleSignIn,
            onAuthenticatedCount: { counter.snapshot }
        )
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
        userID: String = "10000000-0000-4000-8000-000000000001"
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "accessToken": accessToken,
            "accessTokenExpiresAt": "2026-09-23T21:15:00.000Z",
            "refreshToken": "\(accessToken)-refresh",
            "userID": userID,
            "deviceID": "10000000-0000-4000-8000-000000000002",
            "userKind": userKind,
        ])
    }

    nonisolated private static func errorJSON(code: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "error": [
                "code": code,
                "message": "The request conflicts with current server state.",
                "requestID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "retryable": false,
            ],
        ])
    }
}

@MainActor
private final class StubGoogleSignInProvider: GoogleSignInProviding {
    var result: Result<String, any Error>
    var holdsSignIn = false
    private(set) var signInCallCount = 0
    private var hold: CheckedContinuation<Void, Never>?

    init(result: Result<String, any Error>) {
        self.result = result
    }

    func signIn() async throws -> String {
        signInCallCount += 1
        if holdsSignIn {
            await withCheckedContinuation { hold = $0 }
        }
        return try result.get()
    }

    func releaseHeldSignIn() {
        hold?.resume()
        hold = nil
    }

    func signOut() {}

    func disconnect() async {}

    func handle(_ url: URL) -> Bool {
        false
    }
}

private final class InMemoryPreferenceStore: PreferenceStoring {
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
