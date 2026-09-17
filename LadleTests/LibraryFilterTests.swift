import Foundation
import LadleCore
import XCTest
@testable import Ladle

/// `LibraryFilter` is the single source for what the Recipes filter menu
/// offers and for how every value is worded. The pills under the header read
/// the same titles, so these tests pin that the two call sites cannot drift
/// apart — not the words themselves.
@MainActor
final class LibraryFilterTests: XCTestCase {
    func testEveryOptionInAMenuIsNamedDistinctly() {
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
        let unset = LibraryFilter.time.menuTitle(for: nil)
        let thirty = LibraryFilter.time.menuTitle(for: 30)

        XCTAssertTrue(unset.contains(LibraryFilter.anyTitle))
        XCTAssertTrue(thirty.contains(LibraryFilter.time.optionTitle(30)))
        XCTAssertNotEqual(unset, thirty)
    }

    /// A pill stands alone under the header, so it carries the noun its
    /// submenu label would otherwise supply. Carbs and fat are why: without
    /// it a pills row holding both at one value says the same thing twice
    /// over and names neither.
    func testAPillNamesItsDimensionBecauseItStandsAlone() {
        XCTAssertNotEqual(
            LibraryFilter.carbohydrates.pillTitle(50),
            LibraryFilter.fat.pillTitle(50)
        )
    }

    /// The whole point of the shared source: a pill and its submenu row are
    /// worded off one option list, so neither can name a value the other
    /// does not.
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
                LibraryFilter.time.pillTitle(30),
                LibraryFilter.calories.pillTitle(600),
                LibraryFilter.protein.pillTitle(20),
                LibraryFilter.carbohydrates.pillTitle(50),
                LibraryFilter.fat.pillTitle(25),
            ]
        )

        for filter in LibraryFilter.allCases {
            for option in filter.options {
                XCTAssertTrue(
                    filter.pillTitle(option).contains("\(option)"),
                    "\(filter) pill must carry the value its row shows"
                )
                XCTAssertTrue(
                    filter.optionTitle(option).contains("\(option)"),
                    "\(filter) row must carry the value its pill shows"
                )
            }
        }
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
