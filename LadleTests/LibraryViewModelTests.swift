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

    func testCollectionRowsExposeApprovedOrderAndPresentation() {
        let viewModel = makeViewModel()
        viewModel.load()

        XCTAssertEqual(
            viewModel.collectionRows,
            [
                LibraryCollectionRowPresentation(
                    title: "Ready in 30 minutes",
                    systemImage: "timer",
                    count: 3,
                    collection: .quick,
                    identifier: "quick",
                    showsDivider: true
                ),
                LibraryCollectionRowPresentation(
                    title: "Favorited",
                    systemImage: "heart.fill",
                    count: 2,
                    collection: .favorites,
                    identifier: "favorites",
                    showsDivider: true
                ),
                LibraryCollectionRowPresentation(
                    title: "Haven’t cooked yet",
                    systemImage: "frying.pan",
                    count: 6,
                    collection: .uncooked,
                    identifier: "uncooked",
                    showsDivider: false
                ),
            ]
        )
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
        XCTAssertEqual(
            viewModel.creatorName(
                for: viewModel.actionableImportJobs.first {
                    $0.status == .parsing
                }!
            ),
            "@cook"
        )
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
        XCTAssertEqual(
            viewModel.creatorName(for: job),
            PreviewFixtures.recipes[1].creatorName
        )
    }

    func testDeletingImportRemovesOnlyThatInboxItem() throws {
        let repository = LibraryTestRepository(
            recipes: PreviewFixtures.recipes,
            importJobs: PreviewFixtures.importJobs
        )
        let viewModel = LibraryViewModel(
            repository: repository,
            preferenceStore: LibraryTestPreferenceStore()
        )
        viewModel.load()
        let job = try XCTUnwrap(viewModel.actionableImportJobs.first)

        XCTAssertTrue(viewModel.deleteImport(jobID: job.id))

        XCTAssertFalse(repository.importJobs.contains { $0.id == job.id })
        XCTAssertFalse(
            viewModel.actionableImportJobs.contains { $0.id == job.id }
        )
        XCTAssertEqual(repository.recipes, PreviewFixtures.recipes)
    }

    func testCompletingReviewClearsRecipeAndInboxReviewStatus() throws {
        var recipe = PreviewFixtures.recipes[1]
        recipe.reviewStatus = .needsReview
        let reviewJob = try ImportJob.queued(
            sourceURL: recipe.originalURL,
            source: recipe.source
        )
        .awaitingReview(recipeID: recipe.id)
        let repository = LibraryTestRepository(
            recipes: [recipe],
            importJobs: [reviewJob]
        )
        let completedAt = Date(timeIntervalSince1970: 900)
        let viewModel = LibraryViewModel(
            repository: repository,
            preferenceStore: LibraryTestPreferenceStore(),
            now: { completedAt }
        )
        viewModel.load()

        let reviewed = try XCTUnwrap(
            viewModel.completeReview(recipeID: recipe.id)
        )

        XCTAssertEqual(reviewed.reviewStatus, .ready)
        XCTAssertEqual(reviewed.updatedAt, completedAt)
        XCTAssertEqual(repository.recipes.first?.reviewStatus, .ready)
        XCTAssertEqual(repository.importJobs.first?.status, .ready)
        XCTAssertTrue(viewModel.actionableImportJobs.isEmpty)
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

    func testWatchShufflesRecipesOnceAndKeepsTheOrderAcrossReloads() {
        var shuffleCallCount = 0
        let viewModel = LibraryViewModel(
            repository: LibraryTestRepository(
                recipes: PreviewFixtures.recipes
            ),
            preferenceStore: LibraryTestPreferenceStore(),
            shuffleRecipeIDs: { recipeIDs in
                shuffleCallCount += 1
                return Array(recipeIDs.reversed())
            }
        )

        viewModel.load()

        XCTAssertEqual(
            viewModel.watchRecipes.map(\.id),
            Array(PreviewFixtures.recipes.map(\.id).reversed())
        )

        viewModel.load()

        XCTAssertEqual(
            viewModel.watchRecipes.map(\.id),
            Array(PreviewFixtures.recipes.map(\.id).reversed())
        )
        XCTAssertEqual(shuffleCallCount, 1)
    }

    func testDenseArchiveFactsLeadWithProtein() {
        XCTAssertEqual(
            PreviewFixtures.recipes[0].libraryFacts,
            "38 g P · ≈ 680 cal"
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

    func testDenseArchiveFactsRoundRepeatingPerServingValues() {
        let recipe = Recipe(
            title: "Creamy Italian Sausage Rigatoni",
            source: .tiktok,
            originalURL: URL(string: "https://www.tiktok.com/@cook/video/1")!,
            servings: 11,
            nutrition: Nutrition(
                calories: 625,
                proteinGrams: 55,
                servingBasis: 11,
                isEstimated: true
            )
        )

        XCTAssertEqual(recipe.libraryFacts, "5 g P · ≈ 57 cal")
        XCTAssertEqual(recipe.ladleYieldText, "11 servings")
    }

    func testDenseArchiveFactsOmitNutritionWithInvalidServingBasis() {
        let recipe = Recipe(
            title: "Unknown Batch Soup",
            source: .other,
            originalURL: URL(string: "https://example.com/soup")!,
            totalMinutes: 25,
            servings: 4,
            nutrition: Nutrition(
                calories: 1_200,
                proteinGrams: 120,
                servingBasis: 0,
                isEstimated: true
            )
        )

        XCTAssertNil(recipe.libraryNutrition)
        XCTAssertEqual(recipe.libraryFacts, "")
    }

    func testDenseArchiveFactsOnlyMarkEstimatedCaloriesApproximate() {
        let recipe = Recipe(
            title: "Labelled Soup",
            source: .other,
            originalURL: URL(string: "https://example.com/labelled-soup")!,
            servings: 2,
            nutrition: Nutrition(
                calories: 600,
                proteinGrams: 40,
                servingBasis: 2,
                isEstimated: false
            )
        )

        XCTAssertEqual(recipe.libraryFacts, "20 g P · 300 cal")
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

    func testGalleryDisplayModePersistsAcrossViewModels() {
        let preferences = LibraryTestPreferenceStore()
        let first = LibraryViewModel(
            repository: LibraryTestRepository(),
            preferenceStore: preferences
        )

        first.displayMode = .gallery
        let returning = LibraryViewModel(
            repository: LibraryTestRepository(),
            preferenceStore: preferences
        )

        XCTAssertEqual(returning.displayMode, .gallery)
    }

    func testResetPreferencesRestoresDefaultLibraryPresentation() {
        let preferences = LibraryTestPreferenceStore()
        preferences.set(
            LibraryDisplayMode.list.rawValue,
            forKey: "ladle.library.display-mode"
        )
        preferences.set(true, forKey: "ladle.library.inbox-dismissed")
        preferences.set(true, forKey: "ladle.library.saved-collapsed")
        preferences.set(true, forKey: "ladle.library.comeback-collapsed")

        LibraryViewModel.resetPreferences(in: preferences)
        let viewModel = LibraryViewModel(
            repository: LibraryTestRepository(),
            preferenceStore: preferences
        )

        XCTAssertEqual(viewModel.displayMode, .grid)
        XCTAssertFalse(viewModel.isSavedThisWeekCollapsed)
        XCTAssertFalse(viewModel.isComeBackToCollapsed)
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

        XCTAssertTrue(viewModel.toggleFavorite(recipeID: orzo.id))

        XCTAssertEqual(
            repository.savedRecipes.last?.isFavorite,
            true
        )
        XCTAssertEqual(
            viewModel.visibleRecipes.first { $0.id == orzo.id }?.isFavorite,
            true
        )
    }

    func testFavoriteFailureDoesNotPublishOptimisticState() {
        let repository = LibraryTestRepository(
            recipes: PreviewFixtures.recipes
        )
        repository.saveError = LibraryTestError.unavailable
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

        XCTAssertFalse(viewModel.toggleFavorite(recipeID: orzo.id))

        XCTAssertEqual(
            viewModel.visibleRecipes.first { $0.id == orzo.id }?.isFavorite,
            orzo.isFavorite
        )
        XCTAssertEqual(
            viewModel.operationErrorMessage,
            "That favorite couldn’t be updated."
        )
    }

    func testDiscoveredRecipeStoresTheServerRevisionWithoutAnImportJob() {
        let repository = LibraryTestRepository()
        let viewModel = LibraryViewModel(
            repository: repository,
            preferenceStore: LibraryTestPreferenceStore()
        )
        viewModel.load()
        let recipe = PreviewFixtures.recipes[0]

        XCTAssertTrue(
            viewModel.storeDiscoveredRecipe(
                SavedDiscoverRecipe(recipe: recipe, revision: 7)
            )
        )

        XCTAssertEqual(repository.savedRemoteRevisions[recipe.id], 7)
        XCTAssertEqual(viewModel.visibleRecipes, [recipe])
        XCTAssertTrue(repository.importJobs.isEmpty)
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

    func testReloadFailurePreservesLastSuccessfulSnapshot() {
        let recipes = PreviewFixtures.recipes
        let importJobs = PreviewFixtures.importJobs
        let repository = LibraryTestRepository(
            recipes: recipes,
            importJobs: importJobs
        )
        let viewModel = LibraryViewModel(
            repository: repository,
            preferenceStore: LibraryTestPreferenceStore()
        )
        viewModel.load()

        repository.recipes = []
        repository.importJobs = []
        repository.fetchError = LibraryTestError.unavailable
        viewModel.load()

        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.recipes, recipes)
        XCTAssertEqual(viewModel.importJobs, importJobs)
        XCTAssertEqual(
            viewModel.reloadErrorMessage,
            "Your recipes couldn’t be refreshed."
        )

        repository.fetchError = nil
        repository.recipes = [recipes[0]]
        repository.importJobs = []
        viewModel.load()

        XCTAssertEqual(viewModel.recipes, [recipes[0]])
        XCTAssertTrue(viewModel.importJobs.isEmpty)
        XCTAssertNil(viewModel.reloadErrorMessage)
    }

    func testConflictResolutionIsPublishedAndReloadsTheLibrary() {
        let local = PreviewFixtures.recipes[0]
        var remote = local
        remote.title = "Title from another device"
        let conflict = RecipeSyncConflict(
            localRecipe: local,
            remoteRecipe: remote,
            remoteRevision: 4
        )
        let repository = LibraryTestRepository(
            recipes: [local],
            syncConflicts: [conflict]
        )
        let viewModel = LibraryViewModel(
            repository: repository,
            preferenceStore: LibraryTestPreferenceStore()
        )

        viewModel.load()
        XCTAssertEqual(viewModel.syncConflicts, [conflict])

        XCTAssertTrue(
            viewModel.resolveSyncConflict(
                recipeID: local.id,
                resolution: .acceptRemote
            )
        )

        XCTAssertTrue(viewModel.syncConflicts.isEmpty)
        XCTAssertEqual(viewModel.recipes, [remote])
        XCTAssertEqual(
            repository.resolutions,
            [.init(recipeID: local.id, resolution: .acceptRemote)]
        )
    }

    func testLargeLibraryRemainsDeterministicAcrossCorePresentations() {
        let recipes = largeLibrary(count: 1_000)
        let viewModel = LibraryViewModel(
            repository: LibraryTestRepository(recipes: recipes),
            preferenceStore: LibraryTestPreferenceStore(),
            shuffleRecipeIDs: { Array($0.reversed()) }
        )
        viewModel.load()

        XCTAssertEqual(viewModel.recipes.count, 1_000)
        XCTAssertEqual(viewModel.quickRecipes.count, 510)
        XCTAssertEqual(viewModel.favoriteRecipes.count, 100)
        XCTAssertEqual(viewModel.uncookedRecipes.count, 750)
        XCTAssertEqual(viewModel.watchRecipes.count, 666)
        XCTAssertEqual(
            viewModel.watchRecipes.prefix(3).map(\.title),
            ["Recipe 0998", "Recipe 0997", "Recipe 0995"]
        )

        viewModel.searchText = "Recipe 0042"
        viewModel.sort = .alphabetical
        XCTAssertEqual(viewModel.visibleRecipes.map(\.title), ["Recipe 0042"])

        viewModel.searchText = ""
        viewModel.sort = .cookingTime
        viewModel.favoritesOnly = true
        viewModel.maximumTotalMinutes = 30
        XCTAssertEqual(viewModel.visibleRecipes.count, 51)
        XCTAssertEqual(viewModel.visibleRecipes.first?.totalMinutes, 1)
        XCTAssertEqual(viewModel.visibleRecipes.last?.totalMinutes, 21)
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

    private func largeLibrary(count: Int) -> [Recipe] {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var recipes: [Recipe] = []
        recipes.reserveCapacity(count)
        for index in 0..<count {
            let idText = String(
                format: "00000000-0000-0000-0000-%012d",
                index
            )
            let nutrition = Nutrition(
                calories: Decimal(250 + (index % 500)),
                proteinGrams: Decimal(index % 50),
                carbohydrateGrams: Decimal(index % 80),
                fatGrams: Decimal(index % 30),
                servingBasis: 1,
                isEstimated: true
            )
            recipes.append(
                Recipe(
                    id: UUID(uuidString: idText)!,
                    title: String(format: "Recipe %04d", index),
                    creatorName: "@cook\(index % 20)",
                    source: index.isMultiple(of: 3) ? .other : .tiktok,
                    originalURL: URL(
                        string: "https://example.com/recipes/\(index)"
                    )!,
                    totalMinutes: (index % 60) + 1,
                    servings: 1,
                    nutrition: nutrition,
                    isFavorite: index.isMultiple(of: 10),
                    lastCookedAt: index.isMultiple(of: 4) ? date : nil,
                    createdAt: date.addingTimeInterval(TimeInterval(index)),
                    updatedAt: date
                )
            )
        }
        return recipes
    }
}

@MainActor
private final class LibraryTestRepository:
    RecipeRepository,
    RecipeSyncConflictRepository
{
    struct RecordedResolution: Equatable {
        let recipeID: UUID
        let resolution: RecipeSyncConflictResolution
    }

    var recipes: [Recipe]
    var importJobs: [ImportJob]
    var syncConflicts: [RecipeSyncConflict]
    var savedRecipes: [Recipe] = []
    var savedRemoteRevisions: [UUID: Int] = [:]
    var resolutions: [RecordedResolution] = []
    var fetchError: Error?
    var saveError: Error?

    init(
        recipes: [Recipe] = [],
        importJobs: [ImportJob] = [],
        syncConflicts: [RecipeSyncConflict] = []
    ) {
        self.recipes = recipes
        self.importJobs = importJobs
        self.syncConflicts = syncConflicts
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
        if let saveError {
            throw saveError
        }
        savedRecipes.append(recipe)
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
    }

    func saveRemote(_ recipe: Recipe, revision: Int) throws {
        try save(recipe)
        savedRemoteRevisions[recipe.id] = revision
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

    func deleteImportJob(id: UUID) throws {
        importJobs.removeAll { $0.id == id }
    }

    func seedIfNeeded(
        recipes: [Recipe],
        importJobs: [ImportJob]
    ) throws {}

    func fetchSyncConflicts() throws -> [RecipeSyncConflict] {
        syncConflicts
    }

    func resolveSyncConflict(
        recipeID: UUID,
        resolution: RecipeSyncConflictResolution
    ) throws {
        resolutions.append(
            .init(recipeID: recipeID, resolution: resolution)
        )
        guard let conflict = syncConflicts.first(
            where: { $0.id == recipeID }
        ) else {
            return
        }
        if resolution == .acceptRemote {
            if let remote = conflict.remoteRecipe,
               let index = recipes.firstIndex(
                   where: { $0.id == recipeID }
               ) {
                recipes[index] = remote
            } else {
                recipes.removeAll { $0.id == recipeID }
            }
        }
        syncConflicts.removeAll { $0.id == recipeID }
    }
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
