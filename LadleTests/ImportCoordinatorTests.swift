import Foundation
import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class ImportCoordinatorTests: XCTestCase {
    func testSupportedURLPersistsParsingJobAndReadyRecipe() async throws {
        let repository = ImportTestRepository()
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.submit(
            urlText: "https://www.tiktok.com/@ladle/video/ready-green-curry"
        )

        let recipe = try XCTUnwrap(repository.recipes.first)
        XCTAssertEqual(
            coordinator.state,
            .completed(recipeID: recipe.id)
        )
        XCTAssertEqual(recipe.title, "Weeknight Green Curry")
        XCTAssertEqual(repository.importJobs.count, 1)
        XCTAssertEqual(repository.importJobs.first?.status, .ready)
        XCTAssertEqual(
            coordinator.operation,
            .importJob(try XCTUnwrap(repository.importJobs.first?.id))
        )
    }

    func testMalformedAndUnsupportedURLsDoNotCreateJobs() async {
        let repository = ImportTestRepository()
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.submit(urlText: "not a link")
        XCTAssertEqual(
            coordinator.state,
            .validationFailed(.invalidURL)
        )

        await coordinator.submit(
            urlText: "https://recipes.example.com/lemon-orzo"
        )
        XCTAssertEqual(
            coordinator.state,
            .validationFailed(.unsupportedSource)
        )
        XCTAssertTrue(repository.importJobs.isEmpty)
    }

    func testDuplicateCanOpenExistingOrImportAnotherCopy() async {
        let duplicateURL = URL(
            string: "https://www.instagram.com/reel/ready-green-curry"
        )!
        let existing = importRecipe(
            title: "Existing Green Curry",
            originalURL: duplicateURL
        )
        let repository = ImportTestRepository(recipes: [existing])
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.submit(urlText: duplicateURL.absoluteString)

        XCTAssertEqual(
            coordinator.state,
            .duplicate(existingRecipeID: existing.id)
        )
        XCTAssertEqual(coordinator.existingDuplicate, existing)
        XCTAssertTrue(repository.importJobs.isEmpty)

        await coordinator.importDuplicateCopy()

        XCTAssertEqual(repository.recipes.count, 2)
        XCTAssertNotEqual(repository.recipes.last?.id, existing.id)
    }

    func testGuestLimitBlocksNewImportUntilAccountIsCreated() async {
        let repository = ImportTestRepository(
            recipes: (0..<10).map {
                importRecipe(
                    id: UUID(),
                    title: "Recipe \($0)",
                    originalURL: URL(
                        string: "https://example.com/recipe-\($0)"
                    )!
                )
            }
        )
        let accountSession = AccountSession(
            store: ImportTestPreferenceStore()
        )
        accountSession.continueAsGuest()
        let coordinator = makeCoordinator(
            repository: repository,
            accountSession: accountSession
        )

        await coordinator.submit(
            urlText: "https://youtu.be/ready-green-curry"
        )

        XCTAssertEqual(
            coordinator.state,
            .guestLimit(.limitReached)
        )
        XCTAssertTrue(repository.importJobs.isEmpty)

        accountSession.createFreeAccount()
        await coordinator.continueAfterGuestPrompt()

        XCTAssertEqual(repository.recipes.count, 11)
        XCTAssertEqual(repository.importJobs.first?.status, .ready)
    }

    func testNeedsReviewOutcomePersistsRecipeAndReviewState() async throws {
        let repository = ImportTestRepository()
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.submit(
            urlText: "https://www.instagram.com/reel/needs-review-ragu"
        )

        let recipe = try XCTUnwrap(repository.recipes.first)
        XCTAssertEqual(
            coordinator.state,
            .needsReview(recipeID: recipe.id)
        )
        XCTAssertEqual(recipe.reviewStatus, .needsReview)
        XCTAssertEqual(repository.importJobs.first?.status, .needsReview)
    }

    func testManualRecipeCanContinueThroughTenthGuestPrompt() async {
        let repository = ImportTestRepository(
            recipes: (0..<9).map {
                importRecipe(
                    title: "Recipe \($0)",
                    originalURL: URL(
                        string: "https://example.com/recipe-\($0)"
                    )!
                )
            }
        )
        let accountSession = AccountSession(
            store: ImportTestPreferenceStore()
        )
        accountSession.continueAsGuest()
        let coordinator = makeCoordinator(
            repository: repository,
            accountSession: accountSession
        )

        await coordinator.createManualRecipe(
            title: "Grandma’s Soup",
            details: "Simmer gently."
        )

        XCTAssertEqual(
            coordinator.state,
            .guestLimit(.allowWithAccountPrompt)
        )

        await coordinator.continueAfterGuestPrompt()

        XCTAssertEqual(repository.recipes.count, 10)
        XCTAssertEqual(repository.recipes.last?.title, "Grandma’s Soup")
    }

    func testRetryStoresCorrectionNotesAndCanRecoverParserFailure() async throws {
        let failed = try failedJob(slug: "parser-failed-soup")
        let repository = ImportTestRepository(importJobs: [failed])
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.retry(
            jobID: failed.id,
            correctionNotes: "The sauce uses one cup of stock."
        )

        XCTAssertEqual(repository.importJobs.first?.status, .ready)
        XCTAssertEqual(
            repository.importJobs.first?.correctionNotes,
            "The sauce uses one cup of stock."
        )
        XCTAssertEqual(repository.importJobs.first?.retryCount, 1)
        XCTAssertEqual(repository.recipes.count, 1)
    }

    func testPastedDetailsRecoverPrivateImportWithoutDiscardingLink() async throws {
        let failed = try failedJob(slug: "private-family-pasta")
        let repository = ImportTestRepository(importJobs: [failed])
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.retry(
            jobID: failed.id,
            pastedRecipeText: """
            Family Pasta
            1 pound pasta
            Simmer with tomato sauce.
            """
        )

        XCTAssertEqual(repository.importJobs.first?.status, .ready)
        XCTAssertEqual(
            repository.importJobs.first?.sourceURL,
            failed.sourceURL
        )
        XCTAssertEqual(repository.recipes.first?.title, "Family Pasta")
    }

    func testFailedReimportRetryKeepsCurrentRecipeUntouched() async throws {
        let current = importRecipe(
            title: "Current Usable Recipe",
            originalURL: URL(string: "https://example.com/current")!
        )
        let reimporting = ImportJob.reimporting(
            sourceURL: URL(
                string: "https://www.tiktok.com/@ladle/video/parser-failed-update"
            )!,
            source: .tiktok,
            currentRecipeID: current.id,
            candidateRecipeID: UUID()
        )
        let failed = try reimporting.transitioning(
            to: .failed(.parserUnavailable)
        )
        let repository = ImportTestRepository(
            recipes: [current],
            importJobs: [failed]
        )
        let coordinator = ImportCoordinator(
            repository: repository,
            service: FixedImportService(
                outcome: .failed(.parserUnavailable)
            ),
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.retry(jobID: failed.id)

        XCTAssertEqual(repository.recipes, [current])
        XCTAssertEqual(
            repository.importJobs.first?.currentRecipeID,
            current.id
        )
        XCTAssertNil(repository.importJobs.first?.candidateRecipeID)
        XCTAssertEqual(
            repository.importJobs.first?.status,
            .failed(.parserUnavailable)
        )
    }

    private func makeCoordinator(
        repository: ImportTestRepository,
        accountSession: AccountSession = AccountSession(
            store: ImportTestPreferenceStore()
        )
    ) -> ImportCoordinator {
        ImportCoordinator(
            repository: repository,
            service: DemoImportService(),
            accountSession: accountSession,
            clock: ImmediateImportClock()
        )
    }

    private func failedJob(slug: String) throws -> ImportJob {
        try ImportJob.queued(
            sourceURL: URL(
                string: "https://www.tiktok.com/@ladle/video/\(slug)"
            )!,
            source: .tiktok
        )
        .transitioning(to: .failed(.parserUnavailable))
    }
}

private struct ImmediateImportClock: ImportClock {
    func sleep(for duration: Duration) async throws {}
}

private struct FixedImportService: ImportService {
    let outcome: ImportServiceOutcome

    func importRecipe(
        for job: ImportJob
    ) async throws -> ImportServiceOutcome {
        outcome
    }
}

@MainActor
private final class ImportTestRepository: RecipeRepository {
    var recipes: [Recipe]
    var importJobs: [ImportJob]

    init(
        recipes: [Recipe] = [],
        importJobs: [ImportJob] = []
    ) {
        self.recipes = recipes
        self.importJobs = importJobs
    }

    func fetchRecipes() throws -> [Recipe] {
        recipes
    }

    func fetchRecipe(id: UUID) throws -> Recipe? {
        recipes.first { $0.id == id }
    }

    func save(_ recipe: Recipe) throws {
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
    }

    func deleteRecipe(id: UUID) throws {
        recipes.removeAll { $0.id == id }
    }

    func fetchImportJobs() throws -> [ImportJob] {
        importJobs
    }

    func save(_ importJob: ImportJob) throws {
        if let index = importJobs.firstIndex(
            where: { $0.id == importJob.id }
        ) {
            importJobs[index] = importJob
        } else {
            importJobs.append(importJob)
        }
    }

    func seedIfNeeded(
        recipes: [Recipe],
        importJobs: [ImportJob]
    ) throws {}
}

private final class ImportTestPreferenceStore: PreferenceStoring {
    private var values: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}

private func importRecipe(
    id: UUID = UUID(),
    title: String,
    originalURL: URL
) -> Recipe {
    Recipe(
        id: id,
        title: title,
        source: .other,
        originalURL: originalURL,
        servings: 4
    )
}
