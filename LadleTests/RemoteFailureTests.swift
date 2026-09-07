import Foundation
import LadleCore
import XCTest
@testable import Ladle

final class RemoteFailureTests: XCTestCase {
    private let requestID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let retryAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testClassifiesTransportAndAuthenticationFailures() {
        XCTAssertEqual(RemoteFailure(APIError.transport), .offline)
        XCTAssertEqual(
            RemoteFailure(APIError.authenticationExpired),
            .authenticationExpired
        )
        XCTAssertEqual(
            RemoteFailure(APIError.invalidResponse),
            .invalidResponse
        )
    }

    func testClassifiesRemoteCapacityFailuresAndRetryTiming() throws {
        let rateLimit = try remoteError(
            code: .rateLimited,
            retryable: true,
            details: "\"retryAt\":\"2027-01-15T08:00:00.000Z\""
        )
        let provider = try remoteError(
            code: .providerUnavailable,
            retryable: true
        )
        let quota = try remoteError(code: .quotaExceeded, retryable: false)

        XCTAssertEqual(
            RemoteFailure(APIError.remote(rateLimit)),
            .rateLimited(retryAt: retryAt)
        )
        XCTAssertEqual(
            RemoteFailure(APIError.remote(provider)),
            .serviceUnavailable
        )
        XCTAssertEqual(
            RemoteFailure(APIError.remote(quota)),
            .quotaExceeded
        )
    }

    func testPresentationCopyAndRetryPolicyAreDeterministic() {
        XCTAssertEqual(RemoteFailure.offline.title, "You're offline")
        XCTAssertEqual(RemoteFailure.offline.systemImage, "wifi.slash")
        XCTAssertTrue(RemoteFailure.offline.message.contains("saved recipes"))
        XCTAssertTrue(RemoteFailure.offline.canRetry(at: .distantPast))

        let limited = RemoteFailure.rateLimited(retryAt: retryAt)
        XCTAssertEqual(limited.retryAt, retryAt)
        XCTAssertFalse(limited.canRetry(at: retryAt.addingTimeInterval(-1)))
        XCTAssertTrue(limited.canRetry(at: retryAt))

        XCTAssertFalse(RemoteFailure.quotaExceeded.canRetry(at: retryAt))
        XCTAssertFalse(
            RemoteFailure.authenticationExpired.canRetry(at: retryAt)
        )
    }

    /// Every case says a different thing, and none of them says the wrong
    /// one.
    ///
    /// `.serviceUnavailable` is only ever a parsed 503 or 500 from the API,
    /// so the server demonstrably answered: the copy must not send a cook to
    /// check their Wi-Fi. `.offline` is the transport case and stays about
    /// the connection.
    func testEveryFailureNamesTheRightCulprit() {
        let all: [RemoteFailure] = [
            .offline,
            .serviceUnavailable,
            .rateLimited(retryAt: retryAt),
            .quotaExceeded,
            .authenticationExpired,
            .invalidResponse,
            .unknown,
        ]
        XCTAssertEqual(Set(all.map(\.title)).count, all.count)
        XCTAssertEqual(Set(all.map(\.message)).count, all.count)

        XCTAssertEqual(
            RemoteFailure.serviceUnavailable.title,
            "Overeasy had a problem"
        )
        XCTAssertEqual(
            RemoteFailure.serviceUnavailable.message,
            "Overeasy hit a problem on our side. Try again in a moment."
        )
        for word in ["connection", "offline", "Wi-Fi", "Reconnect"] {
            XCTAssertFalse(
                RemoteFailure.serviceUnavailable.message.contains(word),
                "A 5xx must not be blamed on the cook's connection"
            )
        }

        XCTAssertEqual(RemoteFailure.offline.title, "You're offline")
        XCTAssertTrue(RemoteFailure.offline.message.contains("Reconnect"))
        XCTAssertFalse(
            RemoteFailure.offline.message.contains("our side"),
            "A transport error must not be blamed on the service"
        )
    }

    /// One string, three Account surfaces.
    ///
    /// Sign-in, the profile edits and account deletion each used to carry
    /// their own wording for the same 503. They now all quote the failure —
    /// only the opening sentence naming what did not change is theirs.
    func testAccountSurfacesQuoteTheSharedUnavailableSentence() throws {
        let error = APIError.remote(
            try remoteError(code: .internalError, retryable: true)
        )
        let shared = RemoteFailure.serviceUnavailable.message

        XCTAssertEqual(
            AccountAuthenticationFailure(error, fallback: "unused")?.message,
            shared
        )
        XCTAssertEqual(
            ProfileEditFailure.name(error),
            "Your name is unchanged. \(shared)"
        )
        XCTAssertEqual(
            ProfileEditFailure.photo(error),
            "Your photo is unchanged. \(shared)"
        )
        XCTAssertEqual(
            AccountDeletionFailure(error)?.message,
            "Your account and recipes are unchanged. \(shared)"
        )
    }

    func testDiagnosticReportRetainsRequestIDWithoutShowingServerMessage() throws {
        let remote = try remoteError(
            code: .providerUnavailable,
            retryable: true,
            message: "internal provider secret"
        )
        let report = RemoteFailureReport(APIError.remote(remote))

        XCTAssertEqual(report.failure, .serviceUnavailable)
        XCTAssertEqual(report.requestID, requestID)
        XCTAssertFalse(report.failure.message.contains(remote.message))
    }

    private func remoteError(
        code: RemoteErrorCode,
        retryable: Bool,
        message: String = "server detail",
        details: String? = nil
    ) throws -> RemoteErrorDTO {
        let detailsJSON = details.map { ",\"details\":{\($0)}" } ?? ""
        let json = """
        {
          "error": {
            "code": "\(code.rawValue)",
            "message": "\(message)",
            "retryable": \(retryable),
            "requestID": "\(requestID.uuidString.lowercased())"\(detailsJSON)
          }
        }
        """
        return try RemoteContractJSON.decoder()
            .decode(RemoteErrorEnvelope.self, from: Data(json.utf8))
            .error
    }
}
