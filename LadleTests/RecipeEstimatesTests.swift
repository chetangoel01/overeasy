import Foundation
import LadleCore
import XCTest
@testable import Ladle

/// Which estimates the recipe page keeps on the row they qualify, and which
/// it gathers into the one "About these estimates" note.
final class RecipeEstimatesTests: XCTestCase {
    func testTheNoteListsEachRoutineEstimateOnceAndLeavesRowNotesOnTheirRows() {
        let recipe = Recipe(
            title: "Sheet-pan chicken",
            source: .youtube,
            originalURL: URL(string: "https://example.com/chicken")!,
            totalMinutes: 45,
            servings: 4,
            ingredients: [
                ingredient(
                    "chicken thighs",
                    at: 0,
                    field: "ingredients[0].nutritionAmount",
                    reason: "Estimated average weight of 3 chicken thighs at 125g each"
                ),
                ingredient(
                    "sumac",
                    at: 1,
                    field: "ingredients[1].nutrition",
                    reason: "Not counted: no nutrition record found for sumac."
                ),
                ingredient(
                    "garlic",
                    at: 2,
                    field: "ingredients[2]",
                    reason: "The amount was hard to hear."
                ),
            ],
            nutrition: Nutrition(calories: 560, servingBasis: 1, isEstimated: true),
            uncertainties: [
                FieldUncertainty(
                    field: "total_minutes",
                    reason: "Total time was estimated from the method."
                ),
                FieldUncertainty(
                    field: "servings",
                    reason: "Serving count was estimated from the recipe yield."
                ),
            ]
        )

        XCTAssertEqual(
            recipe.ladleEstimateNotes,
            [
                RecipeEstimateNote(
                    subject: "Time",
                    reason: "Total time was estimated from the method."
                ),
                RecipeEstimateNote(
                    subject: "Servings",
                    reason: "Serving count was estimated from the recipe yield."
                ),
                RecipeEstimateNote(
                    subject: "chicken thighs",
                    reason: "Estimated average weight of 3 chicken thighs at 125g each"
                ),
                RecipeEstimateNote(
                    subject: "Nutrition",
                    reason: "Estimated from the ingredient amounts."
                ),
            ]
        )
        // What stays on a row is what changes how that row should be read:
        // an ingredient the totals left out, and a doubt about the row itself.
        XCTAssertEqual(
            recipe.ingredients
                .compactMap(\.uncertainty)
                .filter { !$0.isRoutineEstimate }
                .map(\.field),
            ["ingredients[1].nutrition", "ingredients[2]"]
        )
    }

    /// Nothing to list hides the disclosure altogether.
    func testARecipeThatEstimatedNothingHasNoNote() {
        let recipe = Recipe(
            title: "Stated",
            source: .tiktok,
            originalURL: URL(string: "https://example.com/stated")!,
            totalMinutes: 20,
            servings: 2,
            nutrition: Nutrition(calories: 300, servingBasis: 1, isEstimated: false)
        )

        XCTAssertTrue(recipe.ladleEstimateNotes.isEmpty)
    }

    private func ingredient(
        _ name: String,
        at index: Int,
        field: String,
        reason: String
    ) -> Ingredient {
        Ingredient(
            normalizedQuantity: 1,
            name: name,
            orderIndex: index,
            uncertainty: FieldUncertainty(field: field, reason: reason)
        )
    }
}
