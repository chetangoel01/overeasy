import Foundation
import LadleCore
import XCTest
@testable import Ladle

final class RemoteImportServiceTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testSubmitUsesClientJobIDAndPersistsParsingRemoteID() async throws {
        var job = ImportJob.reimporting(
            sourceURL: URL(
                string: "https://www.youtube.com/watch?v=ladle-ready"
            )!,
            source: .youtube,
            currentRecipeID: UUID(
                uuidString: "20000000-0000-4000-8000-000000000001"
            )!,
            candidateRecipeID: UUID(
                uuidString: "30000000-0000-4000-8000-000000000001"
            )!,
            id: UUID(
                uuidString: "10000000-0000-4000-8000-000000000001"
            )!
        )
        job.correctionNotes = "Keep the sauce bright."
        let submittedJob = job
        let body = Locked<[String: Any]?>(nil)
        URLProtocolStub.install { request in
            body.withValue {
                $0 = try! JSONSerialization.jsonObject(
                    with: try! URLProtocolStub.bodyData(for: request)
                ) as? [String: Any]
            }
            return (
                Self.response(request, status: 202),
                Self.importJSON(
                    jobID: submittedJob.id,
                    status: "parsing"
                )
            )
        }
        let service = makeService()

        let update = try await service.submit(
            submittedJob,
            allowingDuplicate: false
        )

        XCTAssertEqual(
            update.remoteJobID,
            submittedJob.id.uuidString.lowercased()
        )
        XCTAssertEqual(update.progress, .parsing)
        XCTAssertEqual(
            body.snapshot?["jobID"] as? String,
            submittedJob.id.uuidString.lowercased()
        )
        XCTAssertEqual(
            body.snapshot?["sourceURL"] as? String,
            submittedJob.sourceURL.absoluteString
        )
        XCTAssertEqual(body.snapshot?["allowDuplicate"] as? Bool, false)
        XCTAssertEqual(
            body.snapshot?["idempotencyKey"] as? String,
            submittedJob.id.uuidString.lowercased()
        )
        XCTAssertEqual(
            body.snapshot?["currentRecipeID"] as? String,
            submittedJob.currentRecipeID?.uuidString.lowercased()
        )
        XCTAssertEqual(
            body.snapshot?["correctionNotes"] as? String,
            "Keep the sauce bright."
        )
    }

    func testReadyStatusFetchesAndMapsRecipe() async throws {
        let jobID = UUID(
            uuidString: "10000000-0000-4000-8000-000000000001"
        )!
        let paths = Locked<[String]>([])
        URLProtocolStub.install { request in
            paths.withValue { $0.append(request.url?.path ?? "") }
            if request.url?.path == "/v1/imports/\(jobID.uuidString)" {
                return (
                    Self.response(request, status: 200),
                    Self.importJSON(
                        jobID: jobID,
                        status: "ready",
                        recipeID:
                            "20000000-0000-4000-8000-000000000001"
                    )
                )
            }
            return (
                Self.response(request, status: 200),
                try! Self.fixture(named: "recipe-ready")
            )
        }
        let service = makeService()

        let update = try await service.status(
            remoteJobID: jobID.uuidString
        )

        guard case let .ready(recipe) = update.progress else {
            return XCTFail("Expected ready recipe")
        }
        XCTAssertEqual(recipe.title, "Lemon Orzo")
        XCTAssertEqual(paths.snapshot, [
            "/v1/imports/\(jobID.uuidString)",
            "/v1/recipes/20000000-0000-4000-8000-000000000001",
        ])
    }

    func testRetrySendsCorrectionsAndPastedText() async throws {
        let jobID = UUID()
        let body = Locked<[String: Any]?>(nil)
        URLProtocolStub.install { request in
            body.withValue {
                $0 = try! JSONSerialization.jsonObject(
                    with: try! URLProtocolStub.bodyData(for: request)
                ) as? [String: Any]
            }
            return (
                Self.response(request, status: 202),
                Self.importJSON(jobID: jobID, status: "parsing")
            )
        }
        let service = makeService()

        let update = try await service.retry(
            remoteJobID: jobID.uuidString,
            correctionNotes: "Use one cup.",
            pastedRecipeText: "Soup\nSimmer."
        )

        XCTAssertEqual(update.progress, .parsing)
        XCTAssertEqual(body.snapshot?["correctionNotes"] as? String, "Use one cup.")
        XCTAssertEqual(body.snapshot?["pastedText"] as? String, "Soup\nSimmer.")
    }

    func testSubmitPreservesStructuredCapacityErrors() async throws {
        let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(Int, String, [String: String]?, RemoteFailure)] = [
            (503, "providerUnavailable", nil, .serviceUnavailable),
            (429, "quotaExceeded", nil, .quotaExceeded),
            (
                429,
                "rateLimited",
                ["retryAt": "2027-01-15T08:00:00.000Z"],
                .rateLimited(retryAt: retryAt)
            ),
        ]

        for value in cases {
            URLProtocolStub.reset()
            URLProtocolStub.install { request in
                (
                    Self.response(request, status: value.0),
                    Self.errorJSON(code: value.1, details: value.2)
                )
            }
            let job = ImportJob.queued(
                sourceURL: URL(string: "https://youtu.be/capacity")!,
                source: .youtube
            )

            do {
                _ = try await makeService().submit(
                    job,
                    allowingDuplicate: false
                )
                XCTFail("Expected structured remote error")
            } catch {
                XCTAssertEqual(RemoteFailure(error), value.3)
            }
        }
    }

    private func makeService() -> RemoteImportService {
        RemoteImportService(
            api: APIClient(
                baseURL: URL(string: "https://api.ladle.test")!,
                session: URLProtocolStub.session(),
                tokenStore: InMemoryAuthTokenStore(
                    tokens: .fixture(accessToken: "access")
                )
            )
        )
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

    private static func importJSON(
        jobID: UUID,
        status: String,
        recipeID: String? = nil
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "createdAt": "2026-07-23T20:15:00.000Z",
            "failureReason": NSNull(),
            "jobID": jobID.uuidString,
            "recipeID": recipeID as Any? ?? NSNull(),
            "retryCount": 0,
            "status": status,
            "updatedAt": "2026-07-23T20:15:00.000Z",
        ])
    }

    private static func errorJSON(
        code: String,
        details: [String: String]?
    ) -> Data {
        var error: [String: Any] = [
            "code": code,
            "message": "Remote capacity failure.",
            "retryable": true,
            "requestID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        ]
        if let details {
            error["details"] = details
        }
        return try! JSONSerialization.data(
            withJSONObject: ["error": error]
        )
    }

    private static func fixture(named name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(
            contentsOf: root
                .appendingPathComponent("Contracts/Fixtures")
                .appendingPathComponent("\(name).json")
        )
    }
}
