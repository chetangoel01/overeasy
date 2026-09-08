import Foundation
import LadleCore
import Observation

/// The one filter the whole app is looking through.
///
/// Recipes, Discover and Watch all read this object, which is the point:
/// choosing a cuisine on the library and then opening Discover should not
/// mean choosing it again. What differs between the tabs is only the
/// mechanism — the library filters its own decoded tags, the two remote
/// feeds hand the same values to the server — and none of that is decided
/// here.
///
/// The diet is not one of the browsing filters, and is deliberately not
/// written from the filter menu. It is asked for once during onboarding and
/// changed in Profile, beside the cook's name, because it is who the cook is
/// rather than what they are looking for this evening. What the filter menu
/// may do is *pause* it — `isDietPaused`, which lives only in memory, so the
/// diet is back on the next launch the way the cuisines and keywords are
/// gone.
@MainActor
@Observable
final class RecipeFilterStore {
    /// Comma-separated raw values, stored the way `LadleAccentColor` stores
    /// its choice: one string, in the app's own preference domain.
    static let dietPreferenceKey = "ladle.filter.diets"

    @ObservationIgnored
    private let preferenceStore: any PreferenceStoring

    /// The cook's diet. Onboarding and the Profile row write it; nothing
    /// else does, and it outlives the launch.
    var diets: Set<DietTag> {
        didSet {
            guard diets != oldValue else { return }
            preferenceStore.set(
                Self.encodeDiets(diets),
                forKey: Self.dietPreferenceKey
            )
            // A diet just chosen is a diet the cook wants applied, whatever
            // a pause earlier in the same launch said.
            isDietPaused = false
        }
    }

    /// The diet, set down for this launch only.
    ///
    /// In memory on purpose. A cook who wants to see everything for one
    /// evening — a dinner they are cooking for somebody else — should not
    /// have to remember to put their own diet back, and a pause that
    /// survived a week would read as a diet that had been forgotten.
    var isDietPaused = false

    /// What the cook is looking for right now: cuisines, keywords and
    /// ingredient terms. The filter menu writes here, and none of it
    /// survives the launch. Its `diets` are always empty — the diet arrives
    /// through `filter` instead.
    var browsingFilter = RecipeFilter()

    /// What every tab actually filters by: the browsing filters, plus the
    /// diet unless it is paused.
    var filter: RecipeFilter {
        var filter = browsingFilter
        filter.diets = isDietPaused ? [] : diets
        return filter
    }

    /// Whether there is a diet to pause at all. Read from what is stored
    /// rather than from `filter`, because a paused diet is still a diet the
    /// cook has — the row that lifts the pause has to stay on screen.
    var hasDiet: Bool { !diets.isEmpty }

    init(preferenceStore: any PreferenceStoring = UserDefaults.standard) {
        self.preferenceStore = preferenceStore
        diets = Self.decodeDiets(
            preferenceStore.string(forKey: Self.dietPreferenceKey)
        )
    }

    /// What "Clear filters" means now: the browse goes, and the diet is put
    /// down rather than thrown away. Clearing is how a cook empties a screen
    /// that a filter emptied, and the diet may be what emptied it — but
    /// deleting it here would make the filter menu a second place the diet
    /// is set, which is the thing this replaces.
    func clearFilters() {
        browsingFilter.clear()
        isDietPaused = true
    }

    /// Put a launch back on no diet at all.
    ///
    /// The empty value is *written*, not removed, for the reason
    /// `-reset-library-preferences` writes the accent rather than removing
    /// it: a value seeded from outside the app — `simctl spawn defaults
    /// write` lands in the simulator's device-level domain — is read
    /// through but cannot be deleted, so only a write in the app's own
    /// domain actually clears it.
    static func resetPreferences(
        in preferenceStore: any PreferenceStoring = UserDefaults.standard
    ) {
        preferenceStore.set("", forKey: dietPreferenceKey)
    }

    private static func encodeDiets(_ diets: Set<DietTag>) -> String {
        DietTag.ordered(diets).tagRawValues.joined(separator: ",")
    }

    /// Unknown members are dropped rather than taken as a corrupt
    /// preference: a diet removed from the vocabulary should cost the cook
    /// that one choice, not every choice they made.
    private static func decodeDiets(_ stored: String?) -> Set<DietTag> {
        Set(
            (stored ?? "")
                .split(separator: ",")
                .compactMap { DietTag(rawValue: String($0)) }
        )
    }
}
