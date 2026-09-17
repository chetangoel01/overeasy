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

    /// The line under the macro tiles: how their calories were counted and,
    /// only when the two whole numbers on screen disagree, what they come to
    /// beside the total.
    ///
    /// It states both figures and stops. Fibre, alcohol and a label's own
    /// rounding all keep 4, 4 and 9 away from a stated total; the app cannot
    /// tell which, so it names no reason and moves neither number. Comparing
    /// the printed strings is what keeps a gap nobody can see — 669.6 beside
    /// 670 — from being explained as "670 of the 670".
    static func macroCalories(
        _ macros: MacroCalories,
        of calories: Decimal?
    ) -> String {
        let basis = "Protein and carbs count 4 kcal a gram, fat 9."
        guard let calories else {
            return basis
        }
        let counted = ladleNumber(macros.total, maximumFractionDigits: 0)
        let stated = ladleNumber(calories, maximumFractionDigits: 0)
        guard counted != stated else {
            return basis
        }
        let gap = macros.total < calories
            ? "That accounts for \(counted) of the \(stated) calories."
            : "That comes to \(counted), more than the \(stated) calories."
        return "\(basis) \(gap)"
    }
}
