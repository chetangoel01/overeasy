import Foundation
import LadleCore
import UIKit
import XCTest
@testable import Ladle

/// Retry on the two Account surfaces that are not sign-in: the profile edits
/// in the header, and account deletion in the sheet.
///
/// Both used to end at an alert with one OK button, which told a cook the
/// service had failed and then left them to find their way back to the
/// control that had failed. These hold Retry to the only thing that makes it
/// worth having: a second request actually on the wire.
@MainActor
final class AccountRetryTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - The profile edits

    func testRetryingANameSaveIssuesASecondRequest() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            Self.failFirstAttempt(request, recording: requests)
        }
        let editor = makeEditor()

        await editor.saveName("Sagrika")

        XCTAssertEqual(
            editor.nameFailure?.message,
            "Your name is unchanged. \(RemoteFailure.serviceUnavailable.message)"
        )
        let retry = try XCTUnwrap(
            editor.nameFailure?.retry,
            "A 500 on our side is exactly what Retry is for"
        )

        await retry()

        XCTAssertEqual(
            requests.snapshot.map(\.url?.path),
            ["/v1/auth/profile", "/v1/auth/profile"],
            "Retry must re-issue the save, not only clear the alert"
        )
        XCTAssertNil(editor.nameFailure)
        XCTAssertFalse(editor.isSavingName)
    }

    func testRetryingAPhotoUploadIssuesASecondRequest() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            Self.failFirstAttempt(request, recording: requests)
        }
        let editor = makeEditor()
        let jpeg = try XCTUnwrap(ProfilePhoto.jpeg(from: Self.picture()))

        await editor.savePhoto(jpeg, showing: Self.picture())

        XCTAssertEqual(
            editor.photoFailure?.message,
            "Your photo is unchanged. \(RemoteFailure.serviceUnavailable.message)"
        )
        XCTAssertNil(
            editor.pendingPhoto,
            "The old picture goes back while the upload has not landed"
        )
        let retry = try XCTUnwrap(editor.photoFailure?.retry)

        await retry()

        XCTAssertEqual(
            requests.snapshot.map(\.url?.path),
            ["/v1/auth/avatar", "/v1/auth/avatar"]
        )
        XCTAssertEqual(requests.snapshot.map(\.httpMethod), ["PUT", "PUT"])
        XCTAssertNil(editor.photoFailure)
        XCTAssertNotNil(
            editor.pendingPhoto,
            "The picture the retry uploaded is the one now shown"
        )
    }

    /// Retry is offered only where sending the same request again could
    /// change the answer.
    func testNoRetryIsOfferedWhereRepeatingWouldNotHelp() async {
        URLProtocolStub.install { request in
            (
                Self.response(request, status: 401),
                Self.errorJSON(code: "authenticationRequired")
            )
        }
        let editor = makeEditor()

        await editor.saveName("Sagrika")

        XCTAssertEqual(
            editor.nameFailure?.message,
            "Your name is unchanged. Sign in again before changing it."
        )
        XCTAssertNil(
            editor.nameFailure?.retry,
            "An expired session is not fixed by sending the same save again"
        )

        editor.reportUnusablePicture("Your photo is unchanged. Nope.")

        XCTAssertNil(
            editor.photoFailure?.retry,
            "A picture the phone could not open never reached the network"
        )
    }

    // MARK: - Account deletion

    func testRetryingAccountDeletionIssuesASecondRequest() async {
        let attempts = Locked(0)
        let deleter = AccountDeleter()
        let request: @MainActor () async throws -> Void = {
            let attempt = attempts.withValue {
                $0 += 1
                return $0
            }
            guard attempt > 1 else {
                throw APIError.remote(Self.remoteError(code: .internalError))
            }
        }

        await deleter.delete(request)

        XCTAssertEqual(
            deleter.failure?.message,
            "Your account and recipes are unchanged. \(RemoteFailure.serviceUnavailable.message)"
        )
        XCTAssertTrue(deleter.canRetry())
        XCTAssertFalse(deleter.didDelete)

        await deleter.retry()

        XCTAssertEqual(
            attempts.snapshot,
            2,
            "Retry must send the deletion again, not only clear the alert"
        )
        XCTAssertTrue(deleter.didDelete)
        XCTAssertNil(deleter.failure)
        XCTAssertFalse(deleter.canRetry())
    }

    func testDeletionRetryIsNotOfferedForAnExpiredSession() async {
        let deleter = AccountDeleter()

        await deleter.delete { throw APIError.authenticationExpired }

        XCTAssertEqual(deleter.failure?.failure, .authenticationExpired)
        XCTAssertFalse(deleter.canRetry())
        XCTAssertFalse(deleter.didDelete)
    }

    // MARK: - Fixtures

    private func makeEditor() -> ProfileEditor {
        let tokenStore = InMemoryAuthTokenStore(
            tokens: .fixture(accessToken: "account-access")
        )
        let accountSession = AccountSession(store: RetryPreferenceStore())
        accountSession.signInWithApple()
        return ProfileEditor(
            accountSession: accountSession,
            authClient: AuthClient(
                api: APIClient(
                    baseURL: URL(string: "https://api.ladle.test")!,
                    session: URLProtocolStub.session(),
                    tokenStore: tokenStore
                ),
                tokenStore: tokenStore,
                accountSession: accountSession,
                installationIdentity: InstallationIdentity(
                    store: RetryPreferenceStore()
                )
            )
        )
    }

    /// A 500 the first time and the profile the second, which is the shape
    /// of the incident this whole change came from.
    nonisolated private static func failFirstAttempt(
        _ request: URLRequest,
        recording requests: Locked<[URLRequest]>
    ) -> (HTTPURLResponse, Data) {
        let attempt = requests.withValue {
            $0.append(request)
            return $0.count
        }
        guard attempt > 1 else {
            return (
                response(request, status: 500),
                errorJSON(code: "internalError")
            )
        }
        return (response(request, status: 200), profileJSON())
    }

    nonisolated private static func picture() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in
            UIColor.orange.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 0, width: 8, height: 8)).fill()
        }
    }

    nonisolated private static func remoteError(
        code: RemoteErrorCode
    ) -> RemoteErrorDTO {
        let json = """
        {
          "error": {
            "code": "\(code.rawValue)",
            "message": "server detail",
            "retryable": true,
            "requestID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
          }
        }
        """
        return try! RemoteContractJSON.decoder()
            .decode(RemoteErrorEnvelope.self, from: Data(json.utf8))
            .error
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

    nonisolated private static func profileJSON() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "userKind": "apple",
            "displayName": "Sagrika",
            "avatarIsCustom": true,
            "createdAt": "2026-09-02T21:15:00.000Z",
        ])
    }

    nonisolated private static func errorJSON(code: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "error": [
                "code": code,
                "message": "server detail",
                "requestID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "retryable": true,
            ],
        ])
    }
}

private final class RetryPreferenceStore: PreferenceStoring {
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
