import Foundation
import LadleCore
import Observation

/// The one filter the whole app is looking through.
///
/// Recipes, Discover and Watch all read this object, which is the point:
/// choosing a diet on the library and then opening Discover should not mean
/// choosing it again. What differs between the tabs is only the mechanism —
/// the library filters its own decoded tags, the two remote feeds hand the
/// same values to the server — and none of that is decided here.
///
/// Diet is stored, the rest is not. A diet is who the cook is, so it
/// outlives the launch the way the accent does; a cuisine or a keyword is
/// what they happen to be browsing for this evening, and a browse that
/// silently resumed a week later would read as an app with recipes missing.
@MainActor
@Observable
final class RecipeFilterStore {
    /// Comma-separated raw values, stored the way `LadleAccentColor` stores
    /// its choice: one string, in the app's own preference domain.
    static let dietPreferenceKey = "ladle.filter.diets"

    @ObservationIgnored
    private let preferenceStore: any PreferenceStoring

    var filter: RecipeFilter {
        didSet {
            guard filter.diets != oldValue.diets else { return }
            preferenceStore.set(
                Self.encodeDiets(filter.diets),
                forKey: Self.dietPreferenceKey
            )
        }
    }

    init(preferenceStore: any PreferenceStoring = UserDefaults.standard) {
        self.preferenceStore = preferenceStore
        filter = RecipeFilter(
            diets: Self.decodeDiets(
                preferenceStore.string(forKey: Self.dietPreferenceKey)
            )
        )
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
