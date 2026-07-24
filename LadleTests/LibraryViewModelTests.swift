import Foundation
import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class LibraryViewModelTests: XCTestCase {
    func testLoadPublishesRecipesAndOnlyActionableImportJobs() {
        let repository = LibraryTestRepository(
            recipes: PreviewFixtures.recipes,
            importJobs: PreviewFixtures.importJobs + [
                readyImportJob(),
            ]
        )
        let viewModel = LibraryViewModel(
            repository: repository,
            preferenceStore: LibraryTestPreferenceStore()
        )

        viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.visibleRecipes.count, 6)
        XCTAssertEqual(
            viewModel.actionableImportJobs.map(\.status),
            [
                .failed(.parserUnavailable),
                .needsReview,
                .parsing,
            ]
        )
    }

    func testSearchSortAndFiltersComposeThroughRecipeQuery() {
        let viewModel = makeViewModel()
        viewModel.load()

        viewModel.searchText = "orzo"
        viewModel.sort = .alphabetical
        viewModel.favoritesOnly = false
        viewModel.maximumTotalMinutes = 35
        viewModel.maximumCalories = 550

        XCTAssertEqual(
            viewModel.visibleRecipes.map(\.title),
            ["One-Pot Lemon Orzo with Feta"]
        )

        viewModel.favoritesOnly = true

        XCTAssertTrue(viewModel.visibleRecipes.isEmpty)
    }

    func testHomeGroupsExposeUsefulRecipeReentryPoints() {
        let viewModel = makeViewModel()
        viewModel.load()

        XCTAssertEqual(viewModel.savedThisWeek.count, 6)
        XCTAssertEqual(
            viewModel.quickRecipes.map(\.title),
            [
                "Whipped Ricotta Toast, Hot Honey",
                "15-Minute Garlic Butter Udon",
                "Crispy Chili Oil Smash Burgers",
            ]
        )
        XCTAssertEqual(viewModel.favoriteRecipes.count, 2)
        XCTAssertEqual(viewModel.uncookedRecipes.count, 6)
    }

    func testCollectionAndMacroFiltersComposeInAllRecipes() {
        var cookedBurger = PreviewFixtures.recipes[0]
        cookedBurger.lastCookedAt = .now
        let recipes = [cookedBurger] + PreviewFixtures.recipes.dropFirst()
        let viewModel = LibraryViewModel(
            repository: LibraryTestRepository(recipes: Array(recipes)),
            preferenceStore: LibraryTestPreferenceStore()
        )
        viewModel.load()

        viewModel.selectedCollection = .uncooked
        viewModel.minimumProtein = 30
        viewModel.maximumCalories = 600

        XCTAssertEqual(
            viewModel.visibleRecipes.map(\.title),
            ["Sheet-Pan Gochujang Chicken"]
        )
    }

    func testMacroFiltersCanBeRemovedIndependently() {
        let viewModel = makeViewModel()
        viewModel.load()
        viewModel.minimumProtein = 30
        viewModel.maximumCarbohydrates = 40

        XCTAssertEqual(
            viewModel.visibleRecipes.map(\.title),
            ["Crispy Chili Oil Smash Burgers"]
        )

        viewModel.removeMaximumCarbohydratesFilter()
        viewModel.maximumFat = 30

        XCTAssertEqual(
            viewModel.visibleRecipes.map(\.title),
            ["Sheet-Pan Gochujang Chicken"]
        )

        viewModel.removeMinimumProteinFilter()
        viewModel.removeMaximumFatFilter()

        XCTAssertEqual(viewModel.visibleRecipes.count, 6)
    }

    func testOpeningHomeCollectionClearsArchiveQueryState() {
        let viewModel = makeViewModel()
        viewModel.searchText = "orzo"
        viewModel.sort = .highestProtein
        viewModel.favoritesOnly = true
        viewModel.maximumTotalMinutes = 15
        viewModel.maximumCalories = 400
        viewModel.minimumProtein = 30
        viewModel.maximumCarbohydrates = 40
        viewModel.maximumFat = 20

        viewModel.showCollection(.quick)

        XCTAssertEqual(viewModel.selectedCollection, .quick)
        XCTAssertEqual(viewModel.sort, .recentlyAdded)
        XCTAssertEqual(viewModel.searchText, "")
        XCTAssertFalse(viewModel.favoritesOnly)
        XCTAssertNil(viewModel.maximumTotalMinutes)
        XCTAssertNil(viewModel.maximumCalories)
        XCTAssertNil(viewModel.minimumProtein)
        XCTAssertNil(viewModel.maximumCarbohydrates)
        XCTAssertNil(viewModel.maximumFat)
    }

    func testDedicatedSearchIgnoresArchiveScopeAndFilters() {
        let viewModel = makeViewModel()
        viewModel.load()
        viewModel.showCollection(.quick)
        viewModel.minimumProtein = 30

        XCTAssertEqual(
            viewModel.searchResults(matching: "orzo").map(\.title),
            ["One-Pot Lemon Orzo with Feta"]
        )
    }

    func testImportAttentionCountExcludesImportsStillParsing() {
        let viewModel = makeViewModel()
        viewModel.load()

        XCTAssertEqual(viewModel.importAttentionCount, 2)
    }

    func testNeedsReviewImportResolvesRecipeForInbox() throws {
        let viewModel = makeViewModel()
        viewModel.load()
        let job = try XCTUnwrap(
            viewModel.actionableImportJobs.first {
                $0.status == .needsReview
            }
        )

        XCTAssertEqual(
            viewModel.recipeForReview(job)?.id,
            PreviewFixtures.recipes[1].id
        )
    }

    func testReimportReviewFallsBackToCurrentRecipeInInbox() throws {
        let current = PreviewFixtures.recipes[1]
        let candidateID = UUID()
        let job = try ImportJob.reimporting(
            sourceURL: current.originalURL,
            source: current.source,
            currentRecipeID: current.id,
            candidateRecipeID: candidateID
        )
        .awaitingReview(recipeID: candidateID)
        let viewModel = LibraryViewModel(
            repository: LibraryTestRepository(
                recipes: [current],
                importJobs: [job]
            ),
            preferenceStore: LibraryTestPreferenceStore()
        )
        viewModel.load()

        XCTAssertEqual(
            viewModel.recipeForReview(job)?.id,
            current.id
        )
    }

    func testWatchIncludesOnlyRecipesSavedFromVideoSources() {
        let manual = Recipe(
            title: "Family Lasagna",
            source: .other,
            originalURL: URL(string: "https://example.com/lasagna")!,
            servings: 8
        )
        let viewModel = LibraryViewModel(
            repository: LibraryTestRepository(
                recipes: PreviewFixtures.recipes + [manual]
            ),
            preferenceStore: LibraryTestPreferenceStore()
        )
        viewModel.load()

        XCTAssertEqual(viewModel.watchRecipes.count, 6)
        XCTAssertFalse(
            viewModel.watchRecipes.contains { $0.source == .other }
        )
    }

    func testDenseArchiveFactsLeadWithProtein() {
        XCTAssertEqual(
            PreviewFixtures.recipes[0].libraryFacts,
            "38 g P · 25 min · ≈ 680 cal"
        )
    }

    func testDenseArchiveFactsScaleNutritionPerServing() {
        let recipe = Recipe(
            title: "Big Batch Soup",
            source: .other,
            originalURL: URL(string: "https://example.com/soup")!,
            servings: 4,
            nutrition: Nutrition(
                calories: 1_200,
                proteinGrams: 120,
                servingBasis: 4,
                isEstimated: true
            )
        )

        XCTAssertEqual(recipe.libraryFacts, "30 g P · ≈ 300 cal")
    }

    func testDisplayModePersistsAcrossViewModels() {
        let preferences = LibraryTestPreferenceStore()
        let first = LibraryViewModel(
            repository: LibraryTestRepository(),
            preferenceStore: preferences
        )

        first.displayMode = .list
        let returning = LibraryViewModel(
            repository: LibraryTestRepository(),
            preferenceStore: preferences
        )

        XCTAssertEqual(returning.displayMode, .list)
    }

    func testTogglingFavoritePersistsAndUpdatesVisibleRecipes() {
        let repository = LibraryTestRepository(
            recipes: PreviewFixtures.recipes
        )
        let viewModel = LibraryViewModel(
            repository: repository,
            preferenceStore: LibraryTestPreferenceStore()
        )
        viewModel.load()
        let orzo = try! XCTUnwrap(
            viewModel.visibleRecipes.first {
                $0.title == "One-Pot Lemon Orzo with Feta"
            }
        )

        viewModel.toggleFavorite(recipeID: orzo.id)

        XCTAssertEqual(
            repository.savedRecipes.last?.isFavorite,
            true
        )
        XCTAssertEqual(
            viewModel.visibleRecipes.first { $0.id == orzo.id }?.isFavorite,
            true
        )
    }

    func testRemovingMaximumTimeKeepsOtherQueryState() {
        let viewModel = makeViewModel()
        viewModel.searchText = "udon"
        viewModel.sort = .calories
        viewModel.favoritesOnly = true
        viewModel.maximumTotalMinutes = 30
        viewModel.maximumCalories = 700

        viewModel.removeMaximumTimeFilter()

        XCTAssertEqual(viewModel.searchText, "udon")
        XCTAssertEqual(viewModel.sort, .calories)
        XCTAssertTrue(viewModel.favoritesOnly)
        XCTAssertNil(viewModel.maximumTotalMinutes)
        XCTAssertEqual(viewModel.maximumCalories, 700)
    }

    func testRepositoryFailureBecomesRecoverableLoadError() {
        let repository = LibraryTestRepository()
        repository.fetchError = LibraryTestError.unavailable
        let viewModel = LibraryViewModel(
            repository: repository,
            preferenceStore: LibraryTestPreferenceStore()
        )

        viewModel.load()

        XCTAssertEqual(
            viewModel.loadState,
            .failed("Your recipes couldn’t be loaded.")
        )
        XCTAssertTrue(viewModel.visibleRecipes.isEmpty)
    }

    private func makeViewModel() -> LibraryViewModel {
        LibraryViewModel(
            repository: LibraryTestRepository(
                recipes: PreviewFixtures.recipes,
                importJobs: PreviewFixtures.importJobs
            ),
            preferenceStore: LibraryTestPreferenceStore(),
            now: {
                PreviewFixtures.recipes.map(\.createdAt).max()!
            }
        )
    }

    private func readyImportJob() -> ImportJob {
        let queued = ImportJob.queued(
            sourceURL: URL(string: "https://example.com/ready")!,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        return try! queued.transitioning(
            to: .ready,
            at: Date(timeIntervalSince1970: 20)
        )
    }
}

@MainActor
private final class LibraryTestRepository: RecipeRepository {
    var recipes: [Recipe]
    var importJobs: [ImportJob]
    var savedRecipes: [Recipe] = []
    var fetchError: Error?

    init(
        recipes: [Recipe] = [],
        importJobs: [ImportJob] = []
    ) {
        self.recipes = recipes
        self.importJobs = importJobs
    }

    func fetchRecipes() throws -> [Recipe] {
        if let fetchError {
            throw fetchError
        }
        return recipes
    }

    func fetchRecipe(id: UUID) throws -> Recipe? {
        recipes.first { $0.id == id }
    }

    func save(_ recipe: Recipe) throws {
        savedRecipes.append(recipe)
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
        if let fetchError {
            throw fetchError
        }
        return importJobs
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

private final class LibraryTestPreferenceStore: PreferenceStoring {
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

private enum LibraryTestError: Error {
    case unavailable
}
