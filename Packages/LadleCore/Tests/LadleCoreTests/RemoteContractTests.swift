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
    func approximateNutritionFixtureCarriesTheMarkerAndNamesTheGap() throws {
        // Totals for what matched, the marker set, and the ingredient that
        // was skipped named twice: once on its own row and once in the
        // recipe-level summary the panel reads.
        let dto: RemoteRecipeDTO = try decodeFixture(
            "recipe-approximate-nutrition"
        )
        let recipe = try dto.recipe()

        #expect(recipe.reviewStatus == .ready)
        #expect(recipe.nutrition?.calories == Decimal(string: "410"))
        #expect(recipe.nutrition?.approximate == true)
        #expect(recipe.ingredients[1].uncertainty?.reason
            == "Not counted: no nutrition record found for garam masala.")
        #expect(recipe.uncertainties.first { $0.field == "nutrition" }?.reason
            == "1 of 2 ingredients not counted: garam masala.")
    }

    @Test
    func aServerWithoutTheApproximateKeyMeansComplete() throws {
        // Older deployments never send the field; their panels are whole.
        var stripped = try fixtureObject("recipe-approximate-nutrition")
        var nutrition = try #require(stripped["nutrition"] as? [String: Any])
        nutrition.removeValue(forKey: "approximate")
        stripped["nutrition"] = nutrition

        let dto = try RemoteContractJSON.decoder().decode(
            RemoteRecipeDTO.self,
            from: JSONSerialization.data(withJSONObject: stripped)
        )

        #expect(try dto.recipe().nutrition?.approximate == false)
    }

    @Test
    func aCompletePanelIsNotMarkedApproximate() throws {
        let dto: RemoteRecipeDTO = try decodeFixture("recipe-ready")

        #expect(try dto.recipe().nutrition?.approximate == false)
    }

    @Test
    func taggedFixtureCarriesAllThreeFamiliesAndItsProposals() throws {
        let dto: RemoteRecipeDTO = try decodeFixture("recipe-ready")
        let recipe = try dto.recipe()

        #expect(recipe.diets == [.vegetarian])
        #expect(recipe.cuisines == [.mediterranean])
        #expect(recipe.keywords == [.onePot, .weeknight])
        // A proposal is text, not vocabulary, and stays that way on the
        // client: nothing can filter on it.
        #expect(recipe.keywordProposals == ["lemony"])
    }

    @Test
    func untaggedFixturesArriveEmptyRatherThanUnfiltered() throws {
        let review: RemoteRecipeDTO = try decodeFixture("recipe-needs-review")
        let approximate: RemoteRecipeDTO = try decodeFixture(
            "recipe-approximate-nutrition"
        )

        for dto in [review, approximate] {
            let recipe = try dto.recipe()
            #expect(recipe.diets.isEmpty)
            #expect(recipe.cuisines.isEmpty)
            #expect(recipe.keywords.isEmpty)
            #expect(recipe.keywordProposals.isEmpty)
        }
    }

    /// The three ways a tag family can arrive, and the one meaning the
    /// client takes from all of them. A build that shipped before the
    /// server grew a keyword must lose the keyword, not the recipe, and a
    /// response from a server that predates tags entirely must still decode.
    @Test
    func absentNullAndUnknownTagsAllDecodeIntoWhatIsKnown() throws {
        let dto: RemoteRecipeDTO = try decodeFixture("recipe-ready")
        let encoded = try RemoteContractJSON.encoder().encode(dto)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object["diets"] = nil
        object["cuisines"] = NSNull()
        object["keywords"] = ["onePot", "tagFromALaterRelease"]
        object["keywordProposals"] = nil

        let decoded = try RemoteContractJSON.decoder().decode(
            RemoteRecipeDTO.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        let recipe = try decoded.recipe()

        #expect(recipe.diets.isEmpty)
        #expect(recipe.cuisines.isEmpty)
        #expect(recipe.keywords == [.onePot])
        #expect(recipe.keywordProposals.isEmpty)
    }

    /// The client never edits tags, and the server reads a missing list as
    /// "leave what is stored". Sending the four keys as explicit nulls is
    /// what stops a rename — which PUTs the whole recipe — from stripping a
    /// library of the tags extraction gave it.
    @Test
    func writingARecipeSendsNullForEveryTagFamily() throws {
        let source: RemoteRecipeDTO = try decodeFixture("recipe-ready")
        let outgoing = RemoteRecipeDTO(
            recipe: try source.recipe(),
            revision: source.revision
        )

        let encoded = try RemoteContractJSON.encode(outgoing)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        for key in ["diets", "cuisines", "keywords", "keywordProposals"] {
            #expect(object[key] is NSNull, "\(key) must travel as null")
        }
    }

    @Test
    func needsReviewFixturePreservesUncertainty() throws {
        let dto: RemoteRecipeDTO = try decodeFixture("recipe-needs-review")
        let recipe = try dto.recipe()

        #expect(recipe.reviewStatus == .needsReview)
        #expect(recipe.servings == 1)
        // No amount was recoverable, so the row says so outright rather
        // than arriving as a quantity nobody can render.
        #expect(recipe.ingredients[0].normalizedQuantity == nil)
        #expect(recipe.ingredients[0].isToTaste)
        #expect(recipe.ingredients[0].uncertainty?.confidence == 0.2)
        #expect(recipe.nutrition == nil)
    }

    @Test
    func aQuantifiedFixtureRowIsNotFlaggedAsHavingNoAmount() throws {
        let dto: RemoteRecipeDTO = try decodeFixture("recipe-ready")
        let recipe = try dto.recipe()

        #expect(recipe.ingredients[0].normalizedQuantity == 2)
        #expect(recipe.ingredients[0].unit == "cup")
        #expect(recipe.ingredients[0].isToTaste == false)
    }

    @Test
    func aServerWithoutTheToTasteKeyMeansTheRowHasAnAmount() throws {
        // Older deployments never send the field. Their rows all carry a
        // quantity, which is exactly what its absence has to mean.
        var stripped = try fixtureObject("recipe-ready")
        var ingredients = try #require(
            stripped["ingredients"] as? [[String: Any]]
        )
        ingredients[0].removeValue(forKey: "isToTaste")
        stripped["ingredients"] = ingredients

        let dto = try RemoteContractJSON.decoder().decode(
            RemoteRecipeDTO.self,
            from: JSONSerialization.data(withJSONObject: stripped)
        )

        #expect(try dto.recipe().ingredients[0].isToTaste == false)
    }

    @Test
    func anIngredientWithNoAmountGoesBackUpSayingSo() throws {
        let ingredient = Ingredient(
            name: "flaky salt",
            isToTaste: true,
            orderIndex: 0
        )

        let object = try JSONSerialization.jsonObject(
            with: RemoteContractJSON.encode(RemoteIngredientDTO(ingredient))
        ) as? [String: Any]

        #expect(object?["isToTaste"] as? Bool == true)
    }

    @Test
    func estimatedTimeFixtureArrivesAsAReadyRecipeWithACaveat() throws {
        // The estimate travels as an uncertainty on total_minutes rather
        // than a new wire field, so nothing here is a migration and the
        // recipe still arrives ready to cook from.
        let dto: RemoteRecipeDTO = try decodeFixture("recipe-estimated-time")
        let recipe = try dto.recipe()

        #expect(recipe.totalMinutes == 25)
        #expect(recipe.preparationMinutes == nil)
        #expect(recipe.cookingMinutes == nil)
        #expect(recipe.reviewStatus == .ready)
        #expect(recipe.uncertainties.map(\.field) == ["total_minutes"])
        #expect(recipe.uncertainties.first?.confidence == nil)
    }

    @Test
    func cancelledImportDecodesAndReportsItselfAsCancelled() throws {
        // An idempotent re-submission can match a job the user already
        // cancelled, so the wire status has to decode rather than fail.
        let payload = Data(
            """
            {
              "jobID": "10000000-0000-4000-8000-000000000001",
              "status": "cancelled",
              "failureReason": null,
              "recipeID": null,
              "retryCount": 0,
              "createdAt": "2026-08-27T12:00:00.000Z",
              "updatedAt": "2026-08-27T12:00:00.000Z"
            }
            """.utf8
        )

        let dto = try RemoteContractJSON.decoder().decode(
            RemoteImportJobDTO.self,
            from: payload
        )

        #expect(dto.status == .cancelled)
        #expect(throws: RemoteContractError.importCancelled) {
            try dto.importStatus()
        }
    }

    @Test
    func aFailureCodeThisBuildDoesNotKnowStillPollsAsAFailedJob() throws {
        // The reason travels inside the poll response, so a strict decode
        // would throw on the whole payload — every job stuck parsing, not
        // just the one that failed — the first time the server learns a code
        // before the app does.
        let payload = Data(
            """
            {
              "jobID": "10000000-0000-4000-8000-000000000001",
              "status": "failed",
              "failureReason": "someCodeFromALaterServer",
              "recipeID": null,
              "retryCount": 0,
              "createdAt": "2026-08-27T12:00:00.000Z",
              "updatedAt": "2026-08-27T12:00:00.000Z"
            }
            """.utf8
        )

        let dto = try RemoteContractJSON.decoder().decode(
            RemoteImportJobDTO.self,
            from: payload
        )

        #expect(
            try dto.importStatus()
                == .failed(.unrecognized("someCodeFromALaterServer"))
        )
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
            .insufficientTextEvidence,
            .photoPostNeedsManualEntry,
            .invalidURL,
            .networkUnavailable,
            .quotaExceeded,
        ])
        #expect(try failures.map { try $0.importStatus() } == [
            .failed(.parserUnavailable),
            .failed(.privateOrDeleted),
            .failed(.unsupportedSource),
            .failed(.insufficientTextEvidence),
            .failed(.photoPostNeedsManualEntry),
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
        #expect(page.items[0].likeCount == 48210)
        #expect(page.nextCursor == 1)
        #expect(page.hasMore)
    }

    @Test
    func shelvesFixtureCarriesAKeywordAndTheWordsToHeadItWith() throws {
        let shelves: RemoteDiscoverShelvesDTO = try decodeFixture(
            "discover-shelves"
        )

        #expect(shelves.shelves.map(\.title) == ["One pot", "High protein"])
        #expect(shelves.shelves.map(\.recipeKeyword) == [.onePot, .highProtein])
        #expect(shelves.shelves[0].items.count == 2)
        #expect(shelves.shelves[0].recipes[1].title == "Chickpea Curry")
        #expect(shelves.shelves[0].recipes[1].likeCount == nil)
    }

    @Test
    func aShelfForAPromotedKeywordStillDrawsWithoutItsFilter() throws {
        /// The vocabulary is the server's, so a shipped build will meet
        /// keywords it does not have. Losing the shelf would be the wrong
        /// answer — the title arrived with it, which is the point of sending
        /// one — so only the offer to filter by it goes.
        let json = Data(
            """
            {"shelves":[{"keyword":"picnic","title":"Picnic","items":[]}]}
            """.utf8
        )

        let shelves = try JSONDecoder().decode(
            RemoteDiscoverShelvesDTO.self,
            from: json
        )

        #expect(shelves.shelves[0].title == "Picnic")
        #expect(shelves.shelves[0].recipeKeyword == nil)
    }

    /// The auth responses are decoded in the app, not here — `AuthTokens`
    /// is a Keychain record and belongs beside the Keychain. What this holds
    /// is the wire shape itself: the field names and the timestamp format
    /// the app's own type has to match, checked against the same fixtures
    /// the backend re-emits byte for byte.
    @Test
    func authFixturesCarryTheProfileAndTheAccountsCreationDate() throws {
        struct Tokens: Decodable {
            let userID: UUID
            let deviceID: UUID
            let userKind: String
            let refreshToken: String?
            let accessTokenExpiresAt: Date
            let displayName: String?
            let avatarURL: URL?
            let avatarIsCustom: Bool
            let createdAt: Date
        }
        struct Profile: Decodable {
            let userKind: String
            let displayName: String?
            let avatarURL: URL?
            let avatarIsCustom: Bool
            let createdAt: Date
        }

        let tokens: Tokens = try decodeFixture("auth-tokens")
        let profile: Profile = try decodeFixture("auth-profile")
        let august = Date(timeIntervalSince1970: 1_786_708_800)

        #expect(tokens.userKind == "google")
        #expect(tokens.displayName == "Priya Raman")
        #expect(tokens.avatarURL?.host == "images.ladle.example")
        #expect(tokens.createdAt == august)
        #expect(profile.userKind == "apple")
        #expect(profile.avatarURL == nil)
        #expect(profile.createdAt == august)

        // The cook chose that one; the Apple account below has no photo at
        // all. Nothing in the URL says which — only this flag does, and the
        // avatar menu offers "Remove Photo" on the strength of it.
        #expect(tokens.avatarIsCustom)
        #expect(tokens.avatarURL?.query?.contains("signature") == true)
        #expect(profile.avatarIsCustom == false)
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
    func requestEncodingCanonicalizesIdentifierFieldsOnly() throws {
        struct Body: Encodable {
            let jobID: UUID
            let ingredientIDs: [UUID]
            let title: String
            let notes: [String]
        }
        let id = UUID(
            uuidString: "10000000-0000-4000-8000-0000000000AA"
        )!
        let uuidShapedText = "550E8400-E29B-41D4-A716-446655440000"

        let data = try RemoteContractJSON.encode(
            Body(
                jobID: id,
                ingredientIDs: [id],
                title: uuidShapedText,
                notes: [uuidShapedText]
            )
        )
        let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]

        #expect(
            object?["jobID"] as? String
                == "10000000-0000-4000-8000-0000000000aa"
        )
        #expect(
            (object?["ingredientIDs"] as? [String])?.first
                == "10000000-0000-4000-8000-0000000000aa"
        )
        #expect(object?["title"] as? String == uuidShapedText)
        #expect((object?["notes"] as? [String])?.first == uuidShapedText)
    }

    @Test
    func uuidShapedUserTextSurvivesRecipeUploadUnchanged() throws {
        // A user can type a UUID into any freeform field. Only identifier
        // fields may be rewritten to the backend's lowercase wire form.
        let uuidShapedText = "550E8400-E29B-41D4-A716-446655440000"
        let recipeID = UUID(
            uuidString: "20000000-0000-4000-8000-0000000000BB"
        )!
        let ingredient = Ingredient(
            quantityText: "2",
            name: uuidShapedText,
            orderIndex: 0
        )
        let recipe = Recipe(
            id: recipeID,
            title: uuidShapedText,
            description: uuidShapedText,
            creatorName: uuidShapedText,
            source: .tiktok,
            originalURL: URL(string: "https://example.com/video")!,
            servings: 2,
            ingredients: [ingredient],
            steps: [
                RecipeStep(
                    orderIndex: 0,
                    instruction: uuidShapedText,
                    ingredientIDs: [ingredient.id]
                ),
            ],
            notes: [uuidShapedText]
        )

        let data = try RemoteContractJSON.encode(
            RemoteRecipeDTO(recipe: recipe, revision: 1)
        )
        let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        let ingredients = object?["ingredients"] as? [[String: Any]]
        let steps = object?["steps"] as? [[String: Any]]

        #expect(object?["title"] as? String == uuidShapedText)
        #expect(object?["description"] as? String == uuidShapedText)
        #expect(object?["creatorName"] as? String == uuidShapedText)
        #expect((object?["notes"] as? [String]) == [uuidShapedText])
        #expect(ingredients?.first?["name"] as? String == uuidShapedText)
        #expect(steps?.first?["instruction"] as? String == uuidShapedText)

        // The genuine identifiers still go out lowercase — including an
        // already-lowercase one, which passes through unchanged.
        #expect(
            object?["id"] as? String
                == "20000000-0000-4000-8000-0000000000bb"
        )
        #expect(
            ingredients?.first?["id"] as? String
                == ingredient.id.uuidString.lowercased()
        )
        #expect(
            (steps?.first?["ingredientIDs"] as? [String])
                == [ingredient.id.uuidString.lowercased()]
        )
    }
}

private func decodeFixture<Value: Decodable>(_ name: String) throws -> Value {
    try RemoteContractJSON.decoder().decode(Value.self, from: fixtureData(name))
}

/// A fixture as loose JSON, for the tests that have to take a key away
/// before decoding it.
private func fixtureObject(_ name: String) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: fixtureData(name))
        as? [String: Any] ?? [:]
}

private func fixtureData(_ name: String) throws -> Data {
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
    return try Data(contentsOf: fixtureURL)
}
