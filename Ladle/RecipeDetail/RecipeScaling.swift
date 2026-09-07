import Foundation
import LadleCore

/// The serving count a cook is reading a recipe at, for as long as the page
/// is open.
///
/// Ephemeral by construction. This is a value in `RecipeDetailView`'s state,
/// so dismissing the page is the undo: nothing is written to the recipe and
/// nothing syncs. The stored `servings` stays what the recipe claims, and the
/// editor's Servings field keeps its own meaning — the yield, not a choice.
struct RecipeScaling: Equatable {
    /// The yield the recipe claims. Scaling is a ratio against it, so a
    /// recipe without a positive one has nothing to scale from.
    let baseServings: Decimal

    /// The count the cook chose. Starts at the stored yield.
    private(set) var servings: Decimal

    init(baseServings: Decimal) {
        self.baseServings = baseServings
        servings = baseServings
    }

    /// Whether the page offers the control at all. A recipe claiming no
    /// servings would divide by zero, so it is left as written.
    var isAvailable: Bool {
        baseServings > 0
    }

    var isScaled: Bool {
        isAvailable && servings != baseServings
    }

    /// `nil` while the page reads the recipe as written. Absence of a factor
    /// is what every row treats as "print the creator's words verbatim", so
    /// the unscaled rule stays exactly the rule #90 settled.
    var multiplier: Decimal? {
        isScaled ? servings / baseServings : nil
    }

    /// The counts the stepper offers. One serving is the floor because half a
    /// serving is not a thing a recipe page can mean; the ceiling is the
    /// contract's, so the control cannot ask for a number the rest of the app
    /// would reject.
    static let range: ClosedRange<Decimal> =
        1...RecipeContractLimits.maximumServings

    var canIncrease: Bool {
        isAvailable && servings < Self.range.upperBound
    }

    var canDecrease: Bool {
        isAvailable && servings > Self.range.lowerBound
    }

    mutating func setServings(_ value: Decimal) {
        guard isAvailable else { return }
        servings = min(
            max(value, Self.range.lowerBound),
            Self.range.upperBound
        )
    }

    mutating func step(by count: Int) {
        setServings(servings + Decimal(count))
    }

    mutating func reset() {
        servings = baseServings
    }

    /// The count the cook chose, said plainly: "6 servings".
    var chosenYieldText: String {
        Self.yieldText(servings)
    }

    /// What the recipe claims, said the same way. `Recipe.ladleYieldText`
    /// hedges an uncertain yield with "About" or replaces it with "Yield
    /// unknown", neither of which can follow the words "Scaled from".
    var baseYieldText: String {
        Self.yieldText(baseServings)
    }

    private static func yieldText(_ value: Decimal) -> String {
        "\(ladleNumber(value)) \(value == 1 ? "serving" : "servings")"
    }
}
