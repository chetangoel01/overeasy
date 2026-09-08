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
        // A recipe is no longer voided for missing ingredients — the totals
        // are kept and marked instead. The whole-recipe failures that remain
        // are the ones that were never about coverage, and they still write
        // their blocker to `nutrition`. There is no panel to put it on, and
        // it is not written for a cook.
        let recipe = recipe(
            nutrition: nil,
            uncertainties: [
                FieldUncertainty(
                    field: "nutrition",
                    reason: "Nutrition enrichment blocked: invalidYield."
                )
            ]
        )

        XCTAssertNil(NutritionNote.uncounted(in: recipe))
    }

    func testTheSummaryIsOfferedForARecipeSyncedBeforeTheMarkerExisted() throws {
        // The marker is derived server-side from rows that did not exist
        // when the September 2 work wrote these notes, so until the host is
        // backfilled a partial recipe arrives with its summary and
        // `approximate: false`. The sheet reads the note, not the marker,
        // and so still says what was left out.
        let recipe = recipe(
            nutrition: estimated,
            uncertainties: [
                FieldUncertainty(
                    field: "nutrition",
                    reason: "2 of 9 ingredients not counted: tamarind, curry leaves."
                )
            ]
        )

        XCTAssertFalse(try XCTUnwrap(recipe.nutrition).approximate)
        XCTAssertEqual(
            NutritionNote.uncounted(in: recipe),
            "2 of 9 ingredients not counted: tamarind, curry leaves."
        )
    }

    func testTheCalorieFigureIsMarkedWhenTheTotalIsIncomplete() {
        let nutrition = Nutrition(
            calories: 520,
            proteinGrams: 21,
            servingBasis: 1,
            isEstimated: true,
            approximate: true
        )

        XCTAssertEqual(nutrition.ladleCalorieText, "≈ 520")
    }

    func testAnEstimateThatCountedEverythingKeepsABareFigure() {
        XCTAssertEqual(estimated.ladleCalorieText, "520")
        // The sheet, Health export and Watch feed keep the marker on every
        // estimate, as they always did; cards reserve it for a short count.
        XCTAssertEqual(estimated.ladleEstimatedCalorieText, "≈ 520")
    }

    func testThereIsNoFigureToMarkWithoutCalories() {
        let nutrition = Nutrition(
            proteinGrams: 21,
            servingBasis: 1,
            isEstimated: true,
            approximate: true
        )

        XCTAssertNil(nutrition.ladleCalorieText)
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
