import Foundation
import Testing
@testable import LadleCore

@Suite("Remote transport contracts")
struct RemoteContractTests {
    @Test
    func readyRecipeFixtureMapsIntoLadleCore() throws {
        let dto: RemoteRecipeDTO = try decodeFixture("recipe-ready")
        let recipe = try dto.recipe()

        #expect(recipe.id.uuidString.lowercased() == "20000000-0000-4000-8000-000000000001")
        #expect(recipe.servings == Decimal(string: "4"))
        #expect(recipe.source == .youtube)
        #expect(recipe.reviewStatus == .ready)
        #expect(recipe.nutrition?.calories == Decimal(string: "540"))
        #expect(recipe.images.first?.remoteURL?.host == "images.ladle.example")
        #expect(recipe.steps.first?.ingredientIDs == [recipe.ingredients[0].id])
    }

    @Test
    func needsReviewFixturePreservesUncertainty() throws {
        let dto: RemoteRecipeDTO = try decodeFixture("recipe-needs-review")
        let recipe = try dto.recipe()

        #expect(recipe.reviewStatus == .needsReview)
        #expect(recipe.servings == 1)
        #expect(recipe.ingredients[0].normalizedQuantity == nil)
        #expect(recipe.ingredients[0].uncertainty?.confidence == 0.2)
        #expect(recipe.nutrition == nil)
    }

    @Test
    func importFixturesMapFlatStatusesIntoDomainEnum() throws {
        let ready: RemoteImportJobDTO = try decodeFixture("import-ready")
        let review: RemoteImportJobDTO = try decodeFixture("import-needs-review")
        let failures: [RemoteImportJobDTO] = try decodeFixture("import-failures")

        #expect(try ready.importStatus() == .ready)
        #expect(try review.importStatus() == .needsReview)
        #expect(failures.map(\.failureReason) == [
            .parserUnavailable,
            .privateOrDeleted,
            .unsupportedSource,
            .invalidURL,
            .networkUnavailable,
            .quotaExceeded,
        ])
        #expect(try failures.map { try $0.importStatus() } == [
            .failed(.parserUnavailable),
            .failed(.privateOrDeleted),
            .failed(.unsupportedSource),
            .failed(.invalidURL),
            .failed(.networkUnavailable),
            .failed(.quotaExceeded),
        ])
    }

    @Test
    func syncFixtureCarriesOrderedUpsertAndTombstone() throws {
        let page: RemoteSyncPageDTO = try decodeFixture("sync-page")

        #expect(page.nextCursor == 2)
        #expect(page.changes.map(\.sequence) == [1, 2])
        #expect(try page.changes[0].recipe?.recipe().reviewStatus == .needsReview)
        #expect(page.changes[1].kind == .delete)
        #expect(page.changes[1].recipe == nil)
    }

    @Test
    func discoverFixtureCarriesPublicSourceDataWithoutUserIdentity() throws {
        let page: RemoteDiscoverPageDTO = try decodeFixture("discover-page")

        #expect(page.items.count == 1)
        #expect(
            page.items[0].sourceID.uuidString.lowercased()
                == "90000000-0000-4000-8000-000000000001"
        )
        #expect(page.items[0].creatorName == "@mia_cooks")
        #expect(page.items[0].source == .tiktok)
        #expect(page.items[0].savedCount == 12)
        #expect(page.items[0].imageURL?.host == "images.ladle.example")
        #expect(page.items[0].savedRecipeID == nil)
    }

    @Test
    func errorFixtureDecodesCodeSpecificDetails() throws {
        let envelopes: [RemoteErrorEnvelope] = try decodeFixture("errors")

        guard case let .duplicate(existingRecipeID) = envelopes[0].error.details else {
            Issue.record("Expected duplicate recipe details")
            return
        }
        #expect(existingRecipeID.uuidString.lowercased() == "20000000-0000-4000-8000-000000000001")

        guard case let .syncConflict(currentRecipe, currentRevision) =
            envelopes[1].error.details
        else {
            Issue.record("Expected sync conflict details")
            return
        }
        #expect(currentRevision == 2)
        #expect(currentRecipe.revision == 2)
        #expect(try currentRecipe.recipe().title == "Tomato Toast")

        guard case let .rateLimit(retryAt) = envelopes[2].error.details else {
            Issue.record("Expected rate limit details")
            return
        }
        #expect(retryAt.timeIntervalSince1970 > 0)
        #expect(envelopes[3].error.details == nil)
    }

    @Test
    func requestEncodingCanonicalizesNestedUUIDs() throws {
        struct Body: Encodable {
            let jobID: UUID
            let nested: [UUID]
        }
        let id = UUID(
            uuidString: "10000000-0000-4000-8000-0000000000AA"
        )!

        let data = try RemoteContractJSON.encode(
            Body(jobID: id, nested: [id])
        )
        let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]

        #expect(
            object?["jobID"] as? String
                == "10000000-0000-4000-8000-0000000000aa"
        )
        #expect(
            (object?["nested"] as? [String])?.first
                == "10000000-0000-4000-8000-0000000000aa"
        )
    }
}

private func decodeFixture<Value: Decodable>(_ name: String) throws -> Value {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtureURL = repositoryRoot
        .appendingPathComponent("Contracts")
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("\(name).json")
    let data = try Data(contentsOf: fixtureURL)
    return try RemoteContractJSON.decoder().decode(Value.self, from: data)
}
