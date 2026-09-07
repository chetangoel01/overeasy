import Foundation
import LadleCore
import XCTest
@testable import Ladle

/// How an ingredient row reads. `quantityText` is what the creator said,
/// verbatim, and `normalizedQuantity` + `unit` are the machine's split of
/// exactly that text — so printing both repeats the unit ("100 g g flour").
/// The two forms have distinct jobs and never combine.
final class IngredientRowTextTests: XCTestCase {
    func testVerbatimQuantityNeverPrintsTheUnitBesideIt() {
        let ingredient = Ingredient(
            quantityText: "100 g",
            normalizedQuantity: 100,
            unit: "g",
            name: "flour",
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText, "100 g flour")
    }

    func testMissingVerbatimQuantityFallsBackToTheSplit() {
        let ingredient = Ingredient(
            normalizedQuantity: 2,
            unit: "cups",
            name: "flour",
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText, "2 cups flour")
    }

    /// A count has no unit. The fallback still has an amount to show.
    func testSplitWithoutAUnitShowsTheAmountAlone() {
        let ingredient = Ingredient(
            normalizedQuantity: 4,
            name: "potato rolls",
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText, "4 potato rolls")
    }

    /// A lone `unit` with no amount either side of it is not an amount, and
    /// a bare "cups flour" is worse than none.
    func testUnitWithoutAnAmountIsNotPrinted() {
        let ingredient = Ingredient(
            unit: "cups",
            name: "flour",
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText, "flour")
    }

    func testAnUnquantifiedIngredientIsJustItsName() {
        let ingredient = Ingredient(name: "flaky salt", orderIndex: 0)

        XCTAssertEqual(ingredient.cookingDetailText, "flaky salt")
    }

    func testPreparationStillTrailsTheRow() {
        let ingredient = Ingredient(
            quantityText: "1 lb",
            normalizedQuantity: 1,
            unit: "lb",
            name: "ground beef",
            preparation: "in four loose balls",
            orderIndex: 0
        )

        XCTAssertEqual(
            ingredient.cookingDetailText,
            "1 lb ground beef — in four loose balls"
        )
    }

    /// Empty strings reach the client: the wire type carries `String?` and
    /// the backend promises no trimming.
    func testEmptyFieldsReadAsAbsent() {
        let ingredient = Ingredient(
            quantityText: "",
            normalizedQuantity: 2,
            unit: "",
            name: "flour",
            preparation: "",
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText, "2 flour")
    }

    /// The demo library is what a reviewer and a screenshot see, so it has
    /// to carry the shape the backend sends: a verbatim phrase that already
    /// contains its unit.
    func testTheDemoLibraryReadsWithItsUnits() {
        let smashBurgers = PreviewFixtures.recipes[0]

        XCTAssertEqual(
            smashBurgers.orderedIngredients[0].cookingDetailText,
            "1 lb ground beef — 80/20, in four loose balls"
        )
        XCTAssertEqual(
            smashBurgers.orderedIngredients[1].cookingDetailText,
            "4 potato rolls — split"
        )
    }

    // MARK: - Scaled rows

    /// No multiplier is the recipe as written, and the creator's words still
    /// win outright. Scaling adds a case; it does not reopen this one.
    func testNoMultiplierLeavesTheRowVerbatim() {
        let ingredient = Ingredient(
            quantityText: "100 g",
            normalizedQuantity: 100,
            unit: "g",
            name: "flour",
            orderIndex: 0
        )

        XCTAssertEqual(
            ingredient.cookingDetailText(scaledBy: nil),
            "100 g flour"
        )
    }

    /// The verbatim phrase is a claim about the yield the creator wrote for.
    /// Once the cook changes the count it is no longer true, so the split
    /// takes over and the amount is rendered from it.
    func testAScaledRowIsRenderedFromTheSplit() {
        let ingredient = Ingredient(
            quantityText: "1½ tsp",
            normalizedQuantity: 1.5,
            unit: "tsp",
            name: "baking powder",
            orderIndex: 0
        )

        XCTAssertEqual(
            ingredient.cookingDetailText(scaledBy: 2),
            "3 tsp baking powder"
        )
    }

    /// Plain decimals, no unit conversion: twice 1½ tsp is 3 tsp, and the app
    /// does not decide that a cook would rather read a tablespoon.
    func testScalingNeverConvertsUnits() {
        let ingredient = Ingredient(
            normalizedQuantity: 1.5,
            unit: "tsp",
            name: "kosher salt",
            orderIndex: 0
        )

        XCTAssertEqual(
            ingredient.cookingDetailText(scaledBy: 4),
            "6 tsp kosher salt"
        )
    }

    /// A third of a cup is an amount somebody measures, so it keeps the two
    /// fraction digits `measuredAmount` renders rather than rounding to a
    /// tenth.
    func testAThirdOfARowKeepsTwoFractionDigits() {
        let ingredient = Ingredient(
            quantityText: "1 cup",
            normalizedQuantity: 1,
            unit: "cup",
            name: "orzo",
            orderIndex: 0
        )

        XCTAssertEqual(
            ingredient.cookingDetailText(scaledBy: Decimal(1) / Decimal(3)),
            "0.33 cup orzo"
        )
    }

    func testAScaledRowStillTrailsItsPreparation() {
        let ingredient = Ingredient(
            quantityText: "1 lb",
            normalizedQuantity: 1,
            unit: "lb",
            name: "ground beef",
            preparation: "in four loose balls",
            orderIndex: 0
        )

        XCTAssertEqual(
            ingredient.cookingDetailText(scaledBy: 2),
            "2 lb ground beef — in four loose balls"
        )
    }

    /// "To taste" has no number to multiply. The row keeps the creator's
    /// words, and the list marks it as the one that did not move.
    func testARowWithoutASplitIsUntouchedByScaling() {
        let ingredient = Ingredient(
            quantityText: "to taste",
            name: "flaky salt",
            orderIndex: 0
        )

        XCTAssertEqual(
            ingredient.cookingDetailText(scaledBy: 3),
            "to taste flaky salt"
        )
    }

    /// The demo library is what a reviewer, a screenshot and the UI test see,
    /// so its rows carry the split the backend sends. #90 left it unset —
    /// "the '½' rows make a half-hearted job of it, and #100 is the change
    /// that needs it".
    func testTheDemoLibraryScales() {
        let smashBurgers = PreviewFixtures.recipes[0]

        XCTAssertEqual(
            smashBurgers.orderedIngredients[0].cookingDetailText(scaledBy: 2),
            "2 lb ground beef — 80/20, in four loose balls"
        )
        XCTAssertEqual(
            smashBurgers.orderedIngredients[1].cookingDetailText(scaledBy: 2),
            "8 potato rolls — split"
        )
        // "½ small white onion", doubled, is a whole one — and no ".00".
        XCTAssertEqual(
            smashBurgers.orderedIngredients[5].cookingDetailText(scaledBy: 2),
            "1 small white onion — shaved thin"
        )
    }
}
