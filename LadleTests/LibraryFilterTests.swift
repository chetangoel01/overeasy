import Foundation
import LadleCore
import XCTest
@testable import Ladle

/// `LibraryFilter` is the single source for what the Recipes filter menu
/// offers and for how every value is worded. The pills under the header read
/// the same titles, so these tests pin both the words and the fact that the
/// two call sites cannot drift apart.
@MainActor
final class LibraryFilterTests: XCTestCase {
    func testEveryDimensionOffersItsOptionsInOrder() {
        XCTAssertEqual(
            LibraryFilter.allCases,
            [.time, .calories, .protein, .carbohydrates, .fat]
        )
        XCTAssertEqual(LibraryFilter.time.options, [15, 30, 45, 60])
        XCTAssertEqual(LibraryFilter.calories.options, [400, 600, 800])
        XCTAssertEqual(LibraryFilter.protein.options, [20, 30, 40])
        XCTAssertEqual(LibraryFilter.carbohydrates.options, [30, 50])
        XCTAssertEqual(LibraryFilter.fat.options, [15, 25])

        XCTAssertEqual(
            LibraryFilter.allCases.map(\.title),
            ["Time", "Calories", "Protein", "Carbohydrates", "Fat"]
        )
    }

    func testEveryOptionIsWordedForACook() {
        XCTAssertEqual(
            LibraryFilter.time.options.map(LibraryFilter.time.optionTitle),
            [
                "15 min or less",
                "30 min or less",
                "45 min or less",
                "60 min or less",
            ]
        )
        XCTAssertEqual(
            LibraryFilter.calories.options
                .map(LibraryFilter.calories.optionTitle),
            ["400 or fewer", "600 or fewer", "800 or fewer"]
        )
        XCTAssertEqual(
            LibraryFilter.protein.options
                .map(LibraryFilter.protein.optionTitle),
            ["20 g or more", "30 g or more", "40 g or more"]
        )
        XCTAssertEqual(
            LibraryFilter.carbohydrates.options
                .map(LibraryFilter.carbohydrates.optionTitle),
            ["Under 30 g", "Under 50 g"]
        )
        XCTAssertEqual(
            LibraryFilter.fat.options.map(LibraryFilter.fat.optionTitle),
            ["Under 15 g", "Under 25 g"]
        )

        for filter in LibraryFilter.allCases {
            let titles = filter.options.map(filter.optionTitle)
            XCTAssertEqual(
                Set(titles).count,
                filter.options.count,
                "\(filter) must name each option distinctly"
            )
            XCTAssertFalse(titles.contains(where: \.isEmpty))
        }
    }

    /// The submenu label carries the current value, so the menu reads as
    /// state before it is opened.
    func testSubmenuTitleCarriesTheCurrentValue() {
        XCTAssertEqual(LibraryFilter.time.menuTitle(for: nil), "Time · Any")
        XCTAssertEqual(
            LibraryFilter.time.menuTitle(for: 30),
            "Time · 30 min or less"
        )
        XCTAssertEqual(
            LibraryFilter.carbohydrates.menuTitle(for: 50),
            "Carbohydrates · Under 50 g"
        )
        XCTAssertEqual(LibraryFilter.anyTitle, "Any")
    }

    /// The whole point of the shared source: a value cannot be named one
    /// thing on the checked menu row and another on the pill that removes it.
    func testPillTitleMatchesThePickerRowForTheSameValue() {
        let viewModel = makeViewModel()
        viewModel.maximumTotalMinutes = 30
        viewModel.maximumCalories = 600
        viewModel.minimumProtein = 20
        viewModel.maximumCarbohydrates = 50
        viewModel.maximumFat = 25

        XCTAssertEqual(
            LibraryFilterChip.chips(for: viewModel).map(\.title),
            [
                LibraryFilter.time.optionTitle(30),
                LibraryFilter.calories.optionTitle(600),
                LibraryFilter.protein.optionTitle(20),
                LibraryFilter.carbohydrates.optionTitle(50),
                LibraryFilter.fat.optionTitle(25),
            ]
        )
    }

    func testPillsCoverFavoritesAndTheSelectedCollection() {
        let viewModel = makeViewModel()
        XCTAssertTrue(LibraryFilterChip.chips(for: viewModel).isEmpty)
        XCTAssertFalse(viewModel.hasActiveFilters)

        viewModel.favoritesOnly = true
        viewModel.selectedCollection = .quick

        XCTAssertEqual(
            LibraryFilterChip.chips(for: viewModel).map(\.title),
            ["Ready in 30 minutes", "Favorites"]
        )
        XCTAssertTrue(viewModel.hasActiveFilters)
    }

    /// A pill removes exactly its own filter, and Reset clears the six the
    /// menu owns while leaving the collection alone — the collection is
    /// navigation, and the menu never offers it.
    func testRemovingAPillAndResettingClearTheRightState() throws {
        let viewModel = makeViewModel()
        viewModel.maximumTotalMinutes = 30
        viewModel.maximumFat = 25

        let timePill = try XCTUnwrap(
            LibraryFilterChip.chips(for: viewModel).first
        )
        timePill.remove()

        XCTAssertNil(viewModel.maximumTotalMinutes)
        XCTAssertEqual(viewModel.maximumFat, 25)

        viewModel.selectedCollection = .favorites
        viewModel.favoritesOnly = true
        viewModel.resetFilters()

        XCTAssertFalse(viewModel.hasActiveFilters)
        XCTAssertNil(viewModel.maximumFat)
        XCTAssertEqual(viewModel.selectedCollection, .favorites)
    }

    private func makeViewModel() -> LibraryViewModel {
        LibraryViewModel(
            repository: FilterTestRepository(),
            preferenceStore: FilterTestPreferenceStore()
        )
    }
}

/// The pills and the reset read filter state only, so the repository never
/// has to hold recipes for these tests.
@MainActor
private final class FilterTestRepository: RecipeRepository {
    func fetchRecipes() throws -> [Recipe] { [] }
    func fetchRecipe(id: UUID) throws -> Recipe? { nil }
    func save(_ recipe: Recipe) throws {}
    func deleteRecipe(id: UUID) throws {}
    func fetchImportJobs() throws -> [ImportJob] { [] }
    func save(_ importJob: ImportJob) throws {}
    func completeReview(recipe: Recipe, importJobs: [ImportJob]) throws {}
    func seedIfNeeded(recipes: [Recipe], importJobs: [ImportJob]) throws {}
}

private final class FilterTestPreferenceStore: PreferenceStoring {
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
