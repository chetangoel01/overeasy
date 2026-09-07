import Foundation
import LadleCore
import XCTest
@testable import Ladle

/// One filter, three tabs, and one of its four families outliving the
/// launch. These pin which family that is, and that clearing it clears it
/// everywhere a launch could read it from.
@MainActor
final class RecipeFilterStoreTests: XCTestCase {
    func testTheDietComesBackAndTheBrowsingFiltersDoNot() {
        let store = FilterStorePreferences()
        let first = RecipeFilterStore(preferenceStore: store)

        first.filter.diets = [.vegan, .glutenFree]
        first.filter.cuisines = [.korean]
        first.filter.keywords = [.weeknight]
        first.filter.addIngredient("chicken")

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

        filters.filter.diets = [.dairyFree, .vegan]

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

        XCTAssertEqual(filters.filter.diets, [.vegan])
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
            RecipeFilterStore(preferenceStore: store).filter.diets.isEmpty
        )
    }

    func testTheLibraryResetClearsTheDietWithEverythingElse() {
        let store = FilterStorePreferences()
        store.set("pescatarian", forKey: RecipeFilterStore.dietPreferenceKey)

        LibraryViewModel.resetPreferences(in: store)

        XCTAssertTrue(
            RecipeFilterStore(preferenceStore: store).filter.diets.isEmpty
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
