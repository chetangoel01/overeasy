import Foundation
import LadleCore
import SwiftData
import XCTest
@testable import Ladle

@MainActor
final class SwiftDataRecipeRepositoryTests: XCTestCase {
    func testRecipeRoundTripPreservesOrderedIngredientsAndSteps() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let recipe = makeRecipe()

        try repository.save(recipe)
        let fetched = try repository.fetchRecipe(id: recipe.id)

        XCTAssertEqual(fetched, recipe)
        XCTAssertEqual(
            fetched?.orderedIngredients.map(\.name),
            ["orzo", "lemon"]
        )
        XCTAssertEqual(
            fetched?.orderedSteps.map(\.instruction),
            ["Toast the orzo.", "Finish with lemon."]
        )
    }

    func testUpdatingRecipePreservesStableIdentifier() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        var recipe = makeRecipe()
        try repository.save(recipe)

        recipe.title = "Updated Lemon Orzo"
        try repository.save(recipe)

        let recipes = try repository.fetchRecipes()
        XCTAssertEqual(recipes.count, 1)
        XCTAssertEqual(recipes.first?.id, recipe.id)
        XCTAssertEqual(recipes.first?.title, "Updated Lemon Orzo")
    }

    func testDeletingRecipeDoesNotDeleteUnrelatedImport() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let recipe = makeRecipe()
        let job = ImportJob.queued(
            sourceURL: URL(string: "https://www.tiktok.com/@cook/video/55")!
        )
        try repository.save(recipe)
        try repository.save(job)

        try repository.deleteRecipe(id: recipe.id)

        XCTAssertNil(try repository.fetchRecipe(id: recipe.id))
        XCTAssertEqual(try repository.fetchImportJobs(), [job])
    }

    func testDeletingImportJobDoesNotDeleteRecipe() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let recipe = makeRecipe()
        let job = ImportJob.queued(
            sourceURL: URL(string: "https://www.tiktok.com/@cook/video/56")!
        )
        try repository.save(recipe)
        try repository.save(job)

        try repository.deleteImportJob(id: job.id)

        XCTAssertTrue(try repository.fetchImportJobs().isEmpty)
        XCTAssertEqual(try repository.fetchRecipe(id: recipe.id), recipe)
    }

    func testFailedReimportKeepsCurrentStoredRecipe() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let current = makeRecipe()
        try repository.save(current)
        let failed = try ImportJob.reimporting(
            sourceURL: current.originalURL,
            currentRecipeID: current.id,
            candidateRecipeID: UUID()
        )
        .transitioning(to: .failed(.parserUnavailable))

        try repository.save(failed)

        XCTAssertEqual(try repository.fetchRecipe(id: current.id), current)
        XCTAssertEqual(
            try repository.fetchImportJobs().first?.currentRecipeID,
            current.id
        )
    }

    func testReimportCandidateRoundTripsAndReplacesAtomically() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let current = makeRecipe()
        var candidate = makeRecipe()
        candidate.title = "Reviewed Lemon Orzo"
        var job = try ImportJob.reimporting(
            sourceURL: current.originalURL,
            currentRecipeID: current.id,
            candidateRecipeID: candidate.id
        )
        .awaitingReview(candidate: candidate)
        try repository.save(current)
        try repository.save(job)

        XCTAssertEqual(
            try repository.fetchImportJobs().first?.reviewCandidate,
            candidate
        )

        candidate.reviewStatus = .ready
        job = try job.transitioning(to: .ready)
        try repository.replaceRecipe(
            id: current.id,
            with: candidate,
            completing: job
        )

        XCTAssertEqual(try repository.fetchRecipes(), [candidate])
        XCTAssertEqual(try repository.fetchImportJobs().first?.status, .ready)
    }

    func testCompletingReviewUpdatesRecipeAndImportAtomically() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        var recipe = makeRecipe()
        recipe.reviewStatus = .needsReview
        var job = try ImportJob.queued(
            sourceURL: recipe.originalURL,
            source: recipe.source
        )
        .awaitingReview(recipeID: recipe.id)
        try repository.save(recipe)
        try repository.save(job)

        recipe.reviewStatus = .ready
        job = try job.transitioning(to: .ready)
        try repository.completeReview(
            recipe: recipe,
            importJobs: [job]
        )

        XCTAssertEqual(
            try repository.fetchRecipe(id: recipe.id)?.reviewStatus,
            .ready
        )
        XCTAssertEqual(
            try repository.fetchImportJobs().first?.status,
            .ready
        )
    }

    func testPreviewSeedingIsIdempotent() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        try repository.seedIfNeeded(
            recipes: PreviewFixtures.recipes,
            importJobs: PreviewFixtures.importJobs
        )
        let firstRecipeIDs = try repository.fetchRecipes().map(\.id)
        let firstJobIDs = try repository.fetchImportJobs().map(\.id)

        try repository.seedIfNeeded(
            recipes: PreviewFixtures.recipes,
            importJobs: PreviewFixtures.importJobs
        )

        XCTAssertFalse(firstRecipeIDs.isEmpty)
        XCTAssertFalse(firstJobIDs.isEmpty)
        XCTAssertEqual(try repository.fetchRecipes().map(\.id), firstRecipeIDs)
        XCTAssertEqual(
            try repository.fetchImportJobs().map(\.id),
            firstJobIDs
        )
    }

    func testLocalMutationTracksBaseRevisionAndRemoteAckClearsIt() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let local = makeRecipe()

        try repository.save(local)

        XCTAssertEqual(
            try repository.pendingRecipeMutations(),
            [.upsert(recipe: local, baseRevision: 0)]
        )

        let remote = RemoteRecipeDTO(recipe: local, revision: 1)
        try repository.markUpsertSynced(remote, pushed: local)
        XCTAssertTrue(try repository.pendingRecipeMutations().isEmpty)

        var edited = local
        edited.title = "Edited Offline"
        try repository.save(edited)
        XCTAssertEqual(
            try repository.pendingRecipeMutations(),
            [.upsert(recipe: edited, baseRevision: 1)]
        )
    }

    func testSyncConflictKeepsLocalDraftAndStoresServerVersion() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        var local = makeRecipe()
        try repository.saveRemote(local, revision: 1)
        local.title = "My Offline Title"
        try repository.save(local)
        var server = local
        server.title = "Server Title"
        let remote = RemoteRecipeDTO(recipe: server, revision: 2)

        try repository.preserveConflict(
            localRecipeID: local.id,
            remoteRecipe: remote,
            remoteRevision: 2
        )

        XCTAssertEqual(try repository.fetchRecipe(id: local.id), local)
        let conflict = try XCTUnwrap(
            repository.syncConflict(recipeID: local.id)
        )
        XCTAssertEqual(conflict.recipe, server)
        XCTAssertEqual(conflict.revision, 2)
        XCTAssertEqual(
            try repository.pendingRecipeMutations(),
            [.upsert(recipe: local, baseRevision: 1)]
        )
    }

    func testKeepingLocalConflictAdvancesItsSyncBase() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        var local = makeRecipe()
        try repository.saveRemote(local, revision: 1)
        local.title = "My Offline Title"
        try repository.save(local)
        var server = local
        server.title = "Server Title"
        try repository.preserveConflict(
            localRecipeID: local.id,
            remoteRecipe: RemoteRecipeDTO(recipe: server, revision: 2),
            remoteRevision: 2
        )

        try repository.resolveSyncConflict(
            recipeID: local.id,
            resolution: .keepLocal
        )

        XCTAssertEqual(try repository.fetchRecipe(id: local.id), local)
        XCTAssertTrue(try repository.fetchSyncConflicts().isEmpty)
        XCTAssertEqual(
            try repository.pendingRecipeMutations(),
            [.upsert(recipe: local, baseRevision: 2)]
        )
    }

    func testAcceptingRemoteConflictReplacesLocalDraft() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        var local = makeRecipe()
        try repository.saveRemote(local, revision: 1)
        local.title = "My Offline Title"
        try repository.save(local)
        var server = local
        server.title = "Server Title"
        try repository.preserveConflict(
            localRecipeID: local.id,
            remoteRecipe: RemoteRecipeDTO(recipe: server, revision: 2),
            remoteRevision: 2
        )

        try repository.resolveSyncConflict(
            recipeID: local.id,
            resolution: .acceptRemote
        )

        XCTAssertEqual(try repository.fetchRecipe(id: local.id), server)
        XCTAssertTrue(try repository.fetchSyncConflicts().isEmpty)
        XCTAssertTrue(try repository.pendingRecipeMutations().isEmpty)
    }

    func testAcceptingRemoteDeletionConflictRemovesLocalRecipe() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        var local = makeRecipe()
        try repository.saveRemote(local, revision: 1)
        local.title = "Edited Offline"
        try repository.save(local)

        // No conflict stored yet: the pulled delete change alone must
        // produce the deletion conflict.
        try repository.applySyncPage(
            makeSyncPage([
                deleteChange(recipeID: local.id, revision: 2, sequence: 5),
            ])
        )

        let conflict = try XCTUnwrap(
            repository.fetchSyncConflicts().first
        )
        XCTAssertNil(conflict.remoteRecipe)

        try repository.resolveSyncConflict(
            recipeID: local.id,
            resolution: .acceptRemote
        )

        XCTAssertNil(try repository.fetchRecipe(id: local.id))
        XCTAssertTrue(try repository.fetchSyncConflicts().isEmpty)
        XCTAssertTrue(try repository.pendingRecipeMutations().isEmpty)
    }

    func testAcknowledgingAPushKeepsAnEditMadeWhileItWasInFlight() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        var recipe = makeRecipe()
        try repository.saveRemote(recipe, revision: 1)
        recipe.isFavorite = true
        try repository.save(recipe)
        let pushed = recipe

        // The PUT is in flight; the user renames the recipe before it lands.
        var edited = pushed
        edited.title = "Miso Ramen"
        try repository.save(edited)

        try repository.markUpsertSynced(
            RemoteRecipeDTO(recipe: pushed, revision: 2),
            pushed: pushed
        )

        XCTAssertEqual(
            try repository.fetchRecipe(id: recipe.id)?.title,
            "Miso Ramen"
        )
        XCTAssertEqual(
            try repository.pendingRecipeMutations(),
            [.upsert(recipe: edited, baseRevision: 2)]
        )
    }

    func testAcknowledgingAPushDoesNotResurrectARecipeDeletedInFlight() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        var recipe = makeRecipe()
        try repository.saveRemote(recipe, revision: 1)
        recipe.isFavorite = true
        try repository.save(recipe)
        let pushed = recipe

        try repository.deleteRecipe(id: recipe.id)

        try repository.markUpsertSynced(
            RemoteRecipeDTO(recipe: pushed, revision: 2),
            pushed: pushed
        )

        XCTAssertNil(try repository.fetchRecipe(id: recipe.id))
        XCTAssertEqual(
            try repository.pendingRecipeMutations(),
            [.delete(recipeID: recipe.id, baseRevision: 2)]
        )
    }

    func testAcknowledgingAnUnchangedPushAdoptsTheServerCopy() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let recipe = makeRecipe()
        try repository.save(recipe)

        try repository.markUpsertSynced(
            RemoteRecipeDTO(recipe: recipe, revision: 1),
            pushed: recipe
        )

        XCTAssertEqual(try repository.fetchRecipe(id: recipe.id), recipe)
        XCTAssertTrue(try repository.pendingRecipeMutations().isEmpty)
    }

    func testTombstoneSurvivesALaterSaveOfTheSameRow() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let recipe = makeRecipe()
        try repository.saveRemote(recipe, revision: 1)
        try repository.deleteRecipe(id: recipe.id)
        XCTAssertNil(try repository.fetchRecipe(id: recipe.id))

        // Any later write to the row — here the conflict a rejected delete
        // preserves — must not bring the recipe back.
        try repository.preserveConflict(
            localRecipeID: recipe.id,
            remoteRecipe: RemoteRecipeDTO(recipe: recipe, revision: 2),
            remoteRevision: 2
        )

        XCTAssertNil(try repository.fetchRecipe(id: recipe.id))
        XCTAssertTrue(try repository.fetchRecipes().isEmpty)
        XCTAssertEqual(
            try repository.pendingRecipeMutations(),
            [.delete(recipeID: recipe.id, baseRevision: 1)]
        )
    }

    func testDeletingARecipeMidFirstUploadQueuesTheServerSideDelete() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let recipe = makeRecipe()
        try repository.save(recipe)

        // The first PUT is in flight; the user deletes the recipe. Nothing
        // is known to exist server-side yet, so the row is hard-deleted.
        try repository.deleteRecipe(id: recipe.id)
        XCTAssertNil(try repository.fetchRecipe(id: recipe.id))

        // The PUT lands: the server now has the recipe at revision 1.
        try repository.markUpsertSynced(
            RemoteRecipeDTO(recipe: recipe, revision: 1),
            pushed: recipe
        )

        // The recipe must stay deleted on this device, and the copy the PUT
        // just created must be queued for a server-side delete.
        XCTAssertNil(try repository.fetchRecipe(id: recipe.id))
        XCTAssertTrue(try repository.fetchRecipes().isEmpty)
        XCTAssertEqual(
            try repository.pendingRecipeMutations(),
            [.delete(recipeID: recipe.id, baseRevision: 1)]
        )
        XCTAssertEqual(try repository.syncConflictCount(), 0)
    }

    func testFirstUploadEchoDoesNotConflictWithTheQueuedServerDelete() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let recipe = makeRecipe()
        try repository.save(recipe)
        try repository.deleteRecipe(id: recipe.id)
        try repository.markUpsertSynced(
            RemoteRecipeDTO(recipe: recipe, revision: 1),
            pushed: recipe
        )

        // The same sync run's pull returns the upload's own change row.
        try repository.applySyncPage(
            makeSyncPage([
                try upsertChange(recipe, revision: 1, sequence: 1),
            ])
        )

        XCTAssertNil(try repository.fetchRecipe(id: recipe.id))
        XCTAssertEqual(try repository.syncConflictCount(), 0)
        XCTAssertEqual(
            try repository.pendingRecipeMutations(),
            [.delete(recipeID: recipe.id, baseRevision: 1)]
        )
    }

    func testDeletingANeverUploadedRecipeQueuesNothing() throws {
        // Created and deleted before any sync: nothing exists server-side,
        // so nothing may be queued and no row may linger.
        let fixture = try makeFixture()
        let repository = fixture.repository
        let recipe = makeRecipe()
        try repository.save(recipe)

        try repository.deleteRecipe(id: recipe.id)

        XCTAssertTrue(try repository.fetchRecipes().isEmpty)
        XCTAssertTrue(try repository.pendingRecipeMutations().isEmpty)
        XCTAssertEqual(
            try fixture.container.mainContext.fetchCount(
                FetchDescriptor<StoredRecipe>()
            ),
            0
        )
    }

    func testRemoteDeleteChangeConvertsAStoredEditConflictToADeleteConflict()
        throws
    {
        let fixture = try makeFixture()
        let repository = fixture.repository
        var local = makeRecipe()
        try repository.saveRemote(local, revision: 4)
        local.title = "My Offline Title"
        try repository.save(local)

        // Another device edited the recipe (revision 5) and then deleted it
        // (revision 6). The push phase preserved a conflict carrying the
        // revision-5 copy; the pull now delivers both change rows.
        var server = local
        server.title = "Server Title"
        try repository.preserveConflict(
            localRecipeID: local.id,
            remoteRecipe: RemoteRecipeDTO(recipe: server, revision: 5),
            remoteRevision: 5
        )
        try repository.applySyncPage(
            makeSyncPage([
                try upsertChange(server, revision: 5, sequence: 100),
                deleteChange(recipeID: local.id, revision: 6, sequence: 101),
            ])
        )

        // The conflict must present as a deletion, not as the stale
        // revision-5 edit.
        let conflict = try XCTUnwrap(repository.fetchSyncConflicts().first)
        XCTAssertNil(conflict.remoteRecipe)
        XCTAssertEqual(conflict.remoteRevision, 6)
        XCTAssertEqual(conflict.localRecipe, local)

        // Accepting the remote side removes the recipe instead of restoring
        // a copy the server will never serve again.
        try repository.resolveSyncConflict(
            recipeID: local.id,
            resolution: .acceptRemote
        )
        XCTAssertNil(try repository.fetchRecipe(id: local.id))
        XCTAssertTrue(try repository.fetchRecipes().isEmpty)
        XCTAssertTrue(try repository.pendingRecipeMutations().isEmpty)
        XCTAssertEqual(try repository.syncConflictCount(), 0)
    }

    func testMatchingLocalAndRemoteDeletesResolveWithoutReview() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let recipe = makeRecipe()
        try repository.saveRemote(recipe, revision: 2)
        try repository.deleteRecipe(id: recipe.id)

        // The other device deleted it too: both sides agree, so there is
        // nothing to review and nothing left to push.
        try repository.applySyncPage(
            makeSyncPage([
                deleteChange(recipeID: recipe.id, revision: 3, sequence: 7),
            ])
        )

        XCTAssertNil(try repository.fetchRecipe(id: recipe.id))
        XCTAssertEqual(try repository.syncConflictCount(), 0)
        XCTAssertTrue(try repository.pendingRecipeMutations().isEmpty)
    }

    func testEmptyAndUnknownRecipeSyncChangesAreHarmless() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository

        // An empty page over an empty store.
        try repository.applySyncPage(makeSyncPage([]))
        XCTAssertTrue(try repository.fetchRecipes().isEmpty)

        // A delete for a recipe this device never had.
        try repository.applySyncPage(
            makeSyncPage([
                deleteChange(recipeID: UUID(), revision: 9, sequence: 1),
            ])
        )
        XCTAssertTrue(try repository.fetchRecipes().isEmpty)
        XCTAssertEqual(try repository.syncConflictCount(), 0)

        // An empty page over a stored conflict leaves it untouched.
        var local = makeRecipe()
        try repository.saveRemote(local, revision: 1)
        local.title = "Edited Offline"
        try repository.save(local)
        var server = local
        server.title = "Server Title"
        try repository.preserveConflict(
            localRecipeID: local.id,
            remoteRecipe: RemoteRecipeDTO(recipe: server, revision: 2),
            remoteRevision: 2
        )
        try repository.applySyncPage(makeSyncPage([]))
        XCTAssertEqual(
            try repository.fetchSyncConflicts().first?.remoteRecipe,
            server
        )
    }

    func testWipingLocalDataClearsEverythingWithoutQueueingTombstones() throws {
        let fixture = try makeFixture()
        let repository = fixture.repository
        let synced = makeRecipe()
        try repository.saveRemote(synced, revision: 3)
        var unsynced = makeRecipe()
        unsynced.title = "Never Pushed"
        try repository.save(unsynced)
        let job = ImportJob.queued(
            sourceURL: URL(string: "https://www.tiktok.com/@cook/video/77")!
        )
        try repository.save(job)

        try repository.wipeAllData()

        XCTAssertTrue(try repository.fetchRecipes().isEmpty)
        XCTAssertTrue(try repository.fetchImportJobs().isEmpty)
        // Sign-out drops the device's copy; the server library must survive,
        // so a wipe may never leave a delete queued for the next push.
        XCTAssertTrue(try repository.pendingRecipeMutations().isEmpty)
        XCTAssertEqual(try repository.syncConflictCount(), 0)
    }

    private func makeFixture() throws -> RepositoryFixture {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: StoredRecipe.self,
            StoredImportJob.self,
            configurations: configuration
        )
        return RepositoryFixture(
            container: container,
            repository: SwiftDataRecipeRepository(
                modelContext: container.mainContext
            )
        )
    }

    /// The sync-page DTOs are decode-only, so tests build them the way the
    /// server does: as contract JSON.
    private func makeSyncPage(
        _ changes: [[String: Any]]
    ) throws -> RemoteSyncPageDTO {
        let payload = try JSONSerialization.data(withJSONObject: [
            "changes": changes,
            "nextCursor": 1,
            "hasMore": false,
        ] as [String: Any])
        return try RemoteContractJSON.decoder().decode(
            RemoteSyncPageDTO.self,
            from: payload
        )
    }

    private func upsertChange(
        _ recipe: Recipe,
        revision: Int,
        sequence: Int
    ) throws -> [String: Any] {
        let dto = RemoteRecipeDTO(recipe: recipe, revision: revision)
        let recipeJSON = try JSONSerialization.jsonObject(
            with: RemoteContractJSON.encoder().encode(dto)
        )
        return syncChange(
            kind: "upsert",
            recipeID: recipe.id,
            revision: revision,
            sequence: sequence,
            recipe: recipeJSON
        )
    }

    private func deleteChange(
        recipeID: UUID,
        revision: Int,
        sequence: Int
    ) -> [String: Any] {
        syncChange(
            kind: "delete",
            recipeID: recipeID,
            revision: revision,
            sequence: sequence,
            recipe: NSNull()
        )
    }

    private func syncChange(
        kind: String,
        recipeID: UUID,
        revision: Int,
        sequence: Int,
        recipe: Any
    ) -> [String: Any] {
        [
            "sequence": sequence,
            "recipeID": recipeID.uuidString,
            "kind": kind,
            "recipeRevision": revision,
            "changedAt": "2026-08-27T12:00:00.000Z",
            "recipe": recipe,
        ]
    }

    private func makeRecipe() -> Recipe {
        let orzoID = UUID()
        let lemonID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        return Recipe(
            id: UUID(),
            title: "One-Pot Lemon Orzo",
            description: "Creamy, bright, and weeknight friendly.",
            creatorName: "Mia Cooks",
            source: .instagram,
            originalURL: URL(
                string: "https://www.instagram.com/reel/lemon-orzo"
            )!,
            preparationMinutes: 10,
            cookingMinutes: 25,
            totalMinutes: 35,
            servings: 4,
            ingredients: [
                Ingredient(
                    id: lemonID,
                    quantityText: "1",
                    unit: nil,
                    name: "lemon",
                    orderIndex: 1
                ),
                Ingredient(
                    id: orzoID,
                    quantityText: "1",
                    unit: "cup",
                    name: "orzo",
                    orderIndex: 0
                ),
            ],
            steps: [
                RecipeStep(
                    orderIndex: 1,
                    instruction: "Finish with lemon.",
                    ingredientIDs: [lemonID]
                ),
                RecipeStep(
                    orderIndex: 0,
                    instruction: "Toast the orzo.",
                    ingredientIDs: [orzoID]
                ),
            ],
            nutrition: Nutrition(
                calories: 520,
                proteinGrams: 18,
                carbohydrateGrams: 70,
                fatGrams: 19,
                servingBasis: 1,
                isEstimated: true
            ),
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}

private struct RepositoryFixture {
    let container: ModelContainer
    let repository: SwiftDataRecipeRepository
}
