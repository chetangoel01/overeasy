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
