import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class RecipeEngagementTests: XCTestCase {
    func testEngagementWordsSayWhatEachNumberCountsAndNeverDrawAZero() {
        let full = EngagementText(
            likeCount: 24_100,
            ratingAverage: 4.6,
            ratingCount: 12,
            savedCount: 18
        )
        XCTAssertEqual(full.likes, "24K likes")
        XCTAssertEqual(full.stars, "4.6")
        XCTAssertEqual(full.raters, "(12)")
        XCTAssertEqual(full.saves, "Saved by 18 cooks")
        XCTAssertEqual(
            full.spoken,
            "Rated 4.6 out of 5 by 12 cooks. Saved by 18 cooks"
        )

        // Under the server's floor there is a count and no average: no
        // stars, and no "(2)" with nothing in front of it.
        let unpublished = EngagementText(
            likeCount: nil,
            ratingAverage: nil,
            ratingCount: 2,
            savedCount: 1
        )
        XCTAssertNil(unpublished.likes)
        XCTAssertNil(unpublished.stars)
        XCTAssertNil(unpublished.raters)
        XCTAssertEqual(unpublished.saves, "Saved by 1 cook")
        XCTAssertEqual(unpublished.spoken, "Saved by 1 cook")

        let nothing = EngagementText(
            likeCount: 0,
            ratingAverage: nil,
            ratingCount: 0,
            savedCount: 0
        )
        XCTAssertNil(nothing.likes)
        XCTAssertNil(nothing.saves)
        XCTAssertFalse(nothing.hasLine)
    }

    func testRatingFillsAtOnceAdoptsTheServersNumbersAndFallsBackOnFailure()
        async
    {
        let sourceID = UUID()
        func engagement(
            average: Double?,
            count: Int,
            mine: Int?
        ) -> SourceEngagement {
            SourceEngagement(
                sourceID: sourceID,
                savedCount: 18,
                ratingAverage: average,
                ratingCount: count,
                myRating: mine
            )
        }
        let service = EngagementTestService()

        // A server without the API, or any other failure: no numbers, and
        // nothing to rate with.
        let unanswered = RecipeEngagementModel(service: service)
        await unanswered.load(sourceID: sourceID)
        await unanswered.rate(5)
        XCTAssertNil(unanswered.engagement)
        XCTAssertFalse(unanswered.canRate)
        XCTAssertTrue(service.writes.isEmpty)

        service.fetchResult = .success(
            engagement(average: nil, count: 2, mine: nil)
        )
        let model = RecipeEngagementModel(service: service)
        await model.load(sourceID: sourceID)
        XCTAssertTrue(model.canRate)

        // The stars are already filled when the request leaves, and the
        // answer — a third rating publishes the average — takes the header.
        var starsWhenSent: Int?
        service.onWrite = { starsWhenSent = model.myRating }
        service.writeResult = .success(
            engagement(average: 4.3, count: 3, mine: 4)
        )
        await model.rate(4)
        XCTAssertEqual(starsWhenSent, 4)
        XCTAssertEqual(model.engagement?.ratingAverage, 4.3)
        XCTAssertEqual(model.myRating, 4)

        service.writeResult = .failure(EngagementTestError.failed)
        await model.rate(2)
        XCTAssertEqual(model.myRating, 4)
        XCTAssertTrue(model.ratingFailed)
        XCTAssertEqual(model.engagement?.ratingAverage, 4.3)

        service.writeResult = .success(
            engagement(average: nil, count: 2, mine: nil)
        )
        await model.rate(nil)
        XCTAssertNil(model.myRating)
        XCTAssertFalse(model.ratingFailed)
        XCTAssertNil(model.engagement?.ratingAverage)
        XCTAssertEqual(service.writes, [4, 2, nil])
    }
}

private enum EngagementTestError: Error {
    case failed
}

@MainActor
private final class EngagementTestService: SourceEngagementServing {
    var fetchResult: Result<SourceEngagement, any Error> =
        .failure(EngagementTestError.failed)
    var writeResult: Result<SourceEngagement, any Error> =
        .failure(EngagementTestError.failed)
    var onWrite: () -> Void = {}
    /// The stars each write asked for; nil is a clear.
    private(set) var writes: [Int?] = []

    func fetchEngagement(sourceID: UUID) async throws -> SourceEngagement {
        try fetchResult.get()
    }

    func rate(sourceID: UUID, stars: Int) async throws -> SourceEngagement {
        try write(stars)
    }

    func clearRating(sourceID: UUID) async throws -> SourceEngagement {
        try write(nil)
    }

    private func write(_ stars: Int?) throws -> SourceEngagement {
        writes.append(stars)
        onWrite()
        return try writeResult.get()
    }
}
