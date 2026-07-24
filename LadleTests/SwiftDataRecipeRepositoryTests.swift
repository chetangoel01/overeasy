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
        try repository.markUpsertSynced(remote)
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
            localRecipe: local,
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
