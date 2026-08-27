import Foundation
import LadleCore
import XCTest
@testable import Ladle

final class DemoImportServiceTests: XCTestCase {
    func testReadySlugReturnsAStableReadyRecipe() async throws {
        let service = DemoImportService()
        let job = ImportJob.queued(
            sourceURL: URL(
                string: "https://www.tiktok.com/@ladle/video/ready-green-curry"
            )!,
            source: .tiktok
        )

        let first = try await service.submit(
            job,
            allowingDuplicate: false
        ).progress
        let second = try await service.submit(
            job,
            allowingDuplicate: false
        ).progress

        guard case let .ready(firstRecipe) = first,
              case let .ready(secondRecipe) = second else {
            return XCTFail("Expected a ready recipe")
        }
        XCTAssertEqual(firstRecipe, secondRecipe)
        XCTAssertEqual(firstRecipe.title, "Weeknight Green Curry")
        XCTAssertEqual(firstRecipe.originalURL, job.sourceURL)
        XCTAssertEqual(firstRecipe.reviewStatus, .ready)
    }

    func testCancelledSlugReportsTheImportAsCancelled() async throws {
        let service = DemoImportService()
        let job = ImportJob.queued(
            sourceURL: URL(
                string: "https://youtu.be/cancelled-elsewhere"
            )!,
            source: .youtube
        )

        do {
            _ = try await service.submit(job, allowingDuplicate: false)
            XCTFail("Expected the cancelled slug to throw")
        } catch RemoteContractError.importCancelled {
            // The coordinator presents this as a cancelled import.
        }
    }

    func testNeedsReviewSlugMarksTheRecipeForReview() async throws {
        let service = DemoImportService()
        let job = ImportJob.queued(
            sourceURL: URL(
                string: "https://www.instagram.com/reel/needs-review-ragu"
            )!,
            source: .instagram
        )

        let outcome = try await service.submit(
            job,
            allowingDuplicate: false
        ).progress

        guard case let .needsReview(recipe) = outcome else {
            return XCTFail("Expected a needs-review recipe")
        }
        XCTAssertEqual(recipe.title, "Sunday Tomato Ragu")
        XCTAssertEqual(recipe.reviewStatus, .needsReview)
        XCTAssertFalse(recipe.uncertainties.isEmpty)
    }

    func testFailureSlugsReturnSpecificRecoverableFailures() async throws {
        let service = DemoImportService()

        let privateOutcome = try await service.submit(
            job(slug: "private-carbonara"),
            allowingDuplicate: false
        ).progress
        let networkOutcome = try await service.submit(
            job(slug: "network-offline-noodles"),
            allowingDuplicate: false
        ).progress
        let parserOutcome = try await service.submit(
            job(slug: "parser-failed-soup"),
            allowingDuplicate: false
        ).progress

        XCTAssertEqual(privateOutcome, .failed(.privateOrDeleted))
        XCTAssertEqual(networkOutcome, .failed(.networkUnavailable))
        XCTAssertEqual(parserOutcome, .failed(.parserUnavailable))
    }

    func testCancellingSlowImportProducesNoOutcome() async {
        let service = DemoImportService(slowDelay: .seconds(30))
        let slowJob = job(slug: "slow-green-curry")
        let task = Task {
            try await service.submit(
                slowJob,
                allowingDuplicate: false
            )
        }

        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: the pure service returns no result to persist.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func job(slug: String) -> ImportJob {
        ImportJob.queued(
            sourceURL: URL(
                string: "https://www.tiktok.com/@ladle/video/\(slug)"
            )!,
            source: .tiktok
        )
    }
}
