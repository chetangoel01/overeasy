import Foundation
import LadleCore
import XCTest
@testable import Ladle

/// One filter, three tabs, and one of its four families outliving the
/// launch. These pin which family that is, that the filter menu can only
/// put it down rather than change it, and that a reset clears it everywhere
/// a launch could read it from.
@MainActor
final class RecipeFilterStoreTests: XCTestCase {
    func testTheDietComesBackAndTheBrowsingFiltersDoNot() {
        let store = FilterStorePreferences()
        let first = RecipeFilterStore(preferenceStore: store)

        first.diets = [.vegan, .glutenFree]
        first.browsingFilter.cuisines = [.korean]
        first.browsingFilter.keywords = [.weeknight]
        first.browsingFilter.addIngredient("chicken")

        let second = RecipeFilterStore(preferenceStore: store)

        XCTAssertEqual(second.filter.diets, [.vegan, .glutenFree])
        XCTAssertTrue(
            second.filter.cuisines.isEmpty,
            "A cuisine is this evening's browsing, not who the cook is"
        )
        XCTAssertTrue(second.filter.keywords.isEmpty)
        XCTAssertTrue(second.filter.ingredients.isEmpty)
    }

    func testTheDietIsStoredUnderItsOwnKeyInVocabularyOrder() {
        let store = FilterStorePreferences()
        let filters = RecipeFilterStore(preferenceStore: store)

        filters.diets = [.dairyFree, .vegan]

        XCTAssertEqual(
            store.string(forKey: RecipeFilterStore.dietPreferenceKey),
            "vegan,dairyFree"
        )
    }

    func testAnUnknownStoredDietCostsOnlyItself() {
        let store = FilterStorePreferences()
        store.set(
            "vegan,ketogenic",
            forKey: RecipeFilterStore.dietPreferenceKey
        )

        let filters = RecipeFilterStore(preferenceStore: store)

        XCTAssertEqual(filters.diets, [.vegan])
    }

    /// `-reset-library-preferences` has to leave a launch on no diet. The
    /// empty value is written rather than removed, because a value seeded
    /// into the simulator's device-level domain is read through but cannot
    /// be deleted — the same reason the accent reset writes.
    func testResettingPreferencesWritesTheDietEmptyRatherThanRemovingIt() {
        let store = FilterStorePreferences()
        store.set("vegan", forKey: RecipeFilterStore.dietPreferenceKey)

        RecipeFilterStore.resetPreferences(in: store)

        XCTAssertEqual(
            store.string(forKey: RecipeFilterStore.dietPreferenceKey),
            "",
            "A removed key would leave a seeded value showing"
        )
        XCTAssertTrue(
            RecipeFilterStore(preferenceStore: store).diets.isEmpty
        )
    }

    /// The pause is the whole point of the filter menu's one diet row: it
    /// takes the diet off the screens without taking it off the cook, and it
    /// never reaches the preference.
    func testPausingTheDietHidesItFromTheFilterButKeepsIt() {
        let store = FilterStorePreferences()
        let filters = RecipeFilterStore(preferenceStore: store)
        filters.diets = [.vegetarian]

        filters.isDietPaused = true

        XCTAssertTrue(
            filters.filter.diets.isEmpty,
            "Every tab reads `filter`, so a pause shows them everything"
        )
        XCTAssertEqual(filters.diets, [.vegetarian])
        XCTAssertTrue(
            filters.hasDiet,
            "The row that lifts the pause has to stay on screen"
        )
        XCTAssertEqual(
            store.string(forKey: RecipeFilterStore.dietPreferenceKey),
            "vegetarian",
            "A pause belongs to this launch, so it never persists"
        )
    }

    /// Like the cuisines and keywords beside it, and unlike the diet itself:
    /// a cook who put their diet down for one evening should not have to
    /// remember to put it back.
    func testAPausedDietIsBackOnTheNextLaunch() {
        let store = FilterStorePreferences()
        let filters = RecipeFilterStore(preferenceStore: store)
        filters.diets = [.pescatarian]
        filters.isDietPaused = true

        let relaunched = RecipeFilterStore(preferenceStore: store)

        XCTAssertFalse(relaunched.isDietPaused)
        XCTAssertEqual(relaunched.filter.diets, [.pescatarian])
    }

    /// Clear filters is how a cook empties a screen a filter emptied, and
    /// the diet may be what emptied it — but the diet is set in Profile, so
    /// this puts it down rather than throwing it away.
    func testClearingTheFiltersPausesTheDietRatherThanDeletingIt() {
        let store = FilterStorePreferences()
        let filters = RecipeFilterStore(preferenceStore: store)
        filters.diets = [.vegan]
        filters.browsingFilter.cuisines = [.korean]

        filters.clearFilters()

        XCTAssertTrue(filters.filter.isEmpty)
        XCTAssertEqual(filters.diets, [.vegan])
        XCTAssertEqual(
            store.string(forKey: RecipeFilterStore.dietPreferenceKey),
            "vegan"
        )
    }

    /// A diet changed in Profile after a pause has to show up at once, or
    /// the Profile row would read as a control that did nothing.
    func testChangingTheDietLiftsAPause() {
        let filters = RecipeFilterStore(
            preferenceStore: FilterStorePreferences()
        )
        filters.diets = [.vegan]
        filters.isDietPaused = true

        filters.diets = [.vegetarian]

        XCTAssertFalse(filters.isDietPaused)
        XCTAssertEqual(filters.filter.diets, [.vegetarian])
    }

    /// "See all" on a Discover keyword shelf. The shelf was composed under
    /// the diet the cook already had on, so the ranked list it opens has to
    /// keep it — and the keyword replaces whatever browsing keyword was on,
    /// because two keywords widen a feed the cook just asked to narrow.
    func testSeeAllOnAShelfPutsItsKeywordInTheSharedFilter() {
        let preferences = FilterStorePreferences()
        let store = RecipeFilterStore(preferenceStore: preferences)
        store.diets = [.vegetarian]
        store.browsingFilter.keywords = [.soup]

        store.showAll(keyword: .weeknight)

        XCTAssertEqual(store.filter.keywords, [.weeknight])
        XCTAssertEqual(store.filter.diets, [.vegetarian])
    }

    func testTheLibraryResetClearsTheDietWithEverythingElse() {
        let store = FilterStorePreferences()
        store.set("pescatarian", forKey: RecipeFilterStore.dietPreferenceKey)

        LibraryViewModel.resetPreferences(in: store)

        XCTAssertTrue(
            RecipeFilterStore(preferenceStore: store).diets.isEmpty
        )
    }
}

private final class FilterStorePreferences: PreferenceStoring {
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
