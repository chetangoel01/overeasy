import Foundation
import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class SyncStatusTests: XCTestCase {
    func testTransitionsFromIdleThroughSyncingToCurrent() {
        let status = SyncStatus()
        let completedAt = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(status.state, .idle)
        XCTAssertNil(status.lastSuccessfulSync)

        status.begin()
        XCTAssertEqual(status.state, .syncing)

        status.succeed(at: completedAt)
        XCTAssertEqual(status.state, .current)
        XCTAssertEqual(status.lastSuccessfulSync, completedAt)
        XCTAssertEqual(status.shortLabel, "Up to date")
    }

    func testFailureClassifiesOfflineAndPreservesLastSuccess() {
        let status = SyncStatus()
        let completedAt = Date(timeIntervalSince1970: 100)
        status.succeed(at: completedAt)

        status.begin()
        status.fail(APIError.transport)

        XCTAssertEqual(status.failure, .offline)
        XCTAssertEqual(status.lastSuccessfulSync, completedAt)
        XCTAssertEqual(status.shortLabel, "Offline")
    }

    func testRateLimitAndAuthenticationHaveDistinctStates() throws {
        let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
        let rateLimit = try remoteError(
            code: .rateLimited,
            details: "\"retryAt\":\"2027-01-15T08:00:00.000Z\""
        )
        let status = SyncStatus()

        status.begin()
        status.fail(APIError.remote(rateLimit))
        XCTAssertEqual(status.failure, .rateLimited(retryAt: retryAt))
        XCTAssertEqual(status.retryAt, retryAt)
        XCTAssertEqual(status.shortLabel, "Try later")

        status.begin()
        status.fail(APIError.authenticationExpired)
        XCTAssertEqual(status.failure, .authenticationExpired)
        XCTAssertEqual(status.shortLabel, "Sign in again")
    }

    func testLaterSuccessRecoversFromFailure() {
        let status = SyncStatus()
        let recoveredAt = Date(timeIntervalSince1970: 200)
        status.begin()
        status.fail(APIError.transport)

        status.begin()
        status.succeed(at: recoveredAt)

        XCTAssertEqual(status.state, .current)
        XCTAssertNil(status.failure)
        XCTAssertEqual(status.lastSuccessfulSync, recoveredAt)
    }

    private func remoteError(
        code: RemoteErrorCode,
        details: String? = nil
    ) throws -> RemoteErrorDTO {
        let detailsJSON = details.map { ",\"details\":{\($0)}" } ?? ""
        let json = """
        {
          "error": {
            "code": "\(code.rawValue)",
            "message": "server detail",
            "retryable": true,
            "requestID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"\(detailsJSON)
          }
        }
        """
        return try RemoteContractJSON.decoder()
            .decode(RemoteErrorEnvelope.self, from: Data(json.utf8))
            .error
    }
}
