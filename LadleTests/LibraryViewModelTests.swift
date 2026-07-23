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
            preferenceStore: LibraryTestPreferenceStore()
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
