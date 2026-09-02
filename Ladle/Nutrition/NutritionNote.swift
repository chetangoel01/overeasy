import Foundation
import LadleCore

/// What the nutrition panel says about the totals beyond the numbers.
enum NutritionNote {
    /// The backend's summary of ingredients its calculation left out.
    ///
    /// An ingredient no food record describes is skipped rather than voiding
    /// the recipe, so a panel can be short by a spice blend and never say so.
    /// The backend writes one recipe-level `nutrition` note when that
    /// happens, and this is the only thing that reads it: while the recipe
    /// has nutrition to show, that field can only be the summary, because a
    /// blocked recipe has no panel to put it on.
    static func uncounted(in recipe: Recipe) -> String? {
        guard recipe.nutrition != nil else {
            return nil
        }
        return recipe.uncertainties.first { $0.field == "nutrition" }?.reason
    }
}
