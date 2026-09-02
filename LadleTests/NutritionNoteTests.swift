import Foundation
import LadleCore
import XCTest
@testable import Ladle

final class NutritionNoteTests: XCTestCase {
    func testSummaryIsReadFromTheRecipeLevelNutritionUncertainty() {
        let recipe = recipe(
            nutrition: estimated,
            uncertainties: [
                FieldUncertainty(
                    field: "ingredients[1].nutrition",
                    reason: "Not counted: no nutrition record found for tomato."
                ),
                FieldUncertainty(
                    field: "nutrition",
                    reason: "1 of 8 ingredients not counted: tomato."
                ),
            ]
        )

        XCTAssertEqual(
            NutritionNote.uncounted(in: recipe),
            "1 of 8 ingredients not counted: tomato."
        )
    }

    func testACompleteRecipeHasNoNote() {
        let recipe = recipe(nutrition: estimated, uncertainties: [])

        XCTAssertNil(NutritionNote.uncounted(in: recipe))
    }

    func testARowNoteAloneIsNotTheSummary() {
        // The panel reads the recipe-level field; a per-ingredient note is
        // rendered under its own row by `IngredientList` instead.
        let recipe = recipe(
            nutrition: estimated,
            uncertainties: [
                FieldUncertainty(
                    field: "ingredients[0].nutrition",
                    reason: "Not counted: no nutrition record found for ghee."
                )
            ]
        )

        XCTAssertNil(NutritionNote.uncounted(in: recipe))
    }

    func testABlockedRecipeNeverOffersItsBlockerAsTheSummary() {
        // `nutrition` carries the blocker when enrichment produced nothing.
        // There is no panel to put it on, and it is not written for a cook.
        let recipe = recipe(
            nutrition: nil,
            uncertainties: [
                FieldUncertainty(
                    field: "nutrition",
                    reason: "Nutrition enrichment blocked: insufficientCoverage."
                )
            ]
        )

        XCTAssertNil(NutritionNote.uncounted(in: recipe))
    }

    private var estimated: Nutrition {
        Nutrition(
            calories: 520,
            proteinGrams: 21,
            carbohydrateGrams: 48,
            fatGrams: 26,
            servingBasis: 1,
            isEstimated: true
        )
    }

    private func recipe(
        nutrition: Nutrition?,
        uncertainties: [FieldUncertainty]
    ) -> Recipe {
        Recipe(
            title: "Paneer Bhurji",
            source: .instagram,
            originalURL: URL(string: "https://www.instagram.com/reel/DbbHIKHM3xr/")!,
            servings: 4,
            nutrition: nutrition,
            uncertainties: uncertainties
        )
    }
}
