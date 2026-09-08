import Foundation
import LadleCore
import XCTest
@testable import Ladle

/// How an ingredient row reads.
///
/// An ingredient is a quantity, a unit and a name, and a row is rendered
/// from exactly those. `quantityText` is the creator's phrase — the same
/// amount in their own spelling — and printing it beside the unit is what
/// had a row reading "100 g g flour". It is never printed now, at any size,
/// on any surface. An ingredient with no amount at all says so with
/// `isToTaste` and reads as its name.
final class IngredientRowTextTests: XCTestCase {
    func testARowIsRenderedFromTheSplitAndNotTheCreatorsPhrase() {
        let ingredient = Ingredient(
            quantityText: "100 g",
            normalizedQuantity: 100,
            unit: "g",
            name: "flour",
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText, "100 g flour")
    }

    /// The phrase is a note. Even one that reads nothing like the split —
    /// a range, a packaged size — leaves the row alone.
    func testAPhraseThatDisagreesWithTheSplitIsStillNotPrinted() {
        let ingredient = Ingredient(
            quantityText: "2-3 16oz cans",
            normalizedQuantity: 2,
            unit: "cans",
            name: "tomatoes",
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText, "2 cans tomatoes")
    }

    /// A count has no unit.
    func testACountShowsItsNumberAlone() {
        let ingredient = Ingredient(
            normalizedQuantity: 4,
            name: "potato rolls",
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText, "4 potato rolls")
    }

    func testAnIngredientWithNoQuantityIsJustItsName() {
        let ingredient = Ingredient(
            quantityText: "to taste",
            name: "flaky salt",
            isToTaste: true,
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText, "flaky salt")
    }

    /// A unit with no number either side of it is not an amount, and a row
    /// reading "cups flour" is worse than one reading "flour". The server
    /// no longer sends this; a library stored before it could.
    func testAUnitWithoutANumberIsNotPrinted() {
        let ingredient = Ingredient(
            unit: "cups",
            name: "flour",
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText, "flour")
    }

    func testPreparationStillTrailsTheRow() {
        let ingredient = Ingredient(
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

    /// A quarter cup is an amount somebody measures, so the number keeps
    /// two fraction digits where a nutrition figure keeps one.
    func testAFractionalAmountKeepsThePrecisionACookMeasures() {
        let ingredient = Ingredient(
            normalizedQuantity: Decimal(string: "0.25"),
            unit: "cup",
            name: "milk",
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText, "0.25 cup milk")
    }

    /// The backend stores decimals at the column's scale, so "2" arrives as
    /// "2.000000" and must not be printed that way.
    func testATrailingZeroAmountReadsAsAWholeNumber() {
        let ingredient = Ingredient(
            normalizedQuantity: Decimal(string: "2.000000"),
            unit: "cups",
            name: "flour",
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText, "2 cups flour")
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

    func testScalingMultipliesTheAmountAndKeepsTheUnit() {
        let ingredient = Ingredient(
            quantityText: "2 cups",
            normalizedQuantity: 2,
            unit: "cups",
            name: "flour",
            orderIndex: 0
        )

        XCTAssertEqual(
            ingredient.cookingDetailText(scaledBy: Decimal(string: "1.5")!),
            "3 cups flour"
        )
    }

    /// A pinch does not double.
    func testScalingLeavesAnIngredientWithNoQuantityAlone() {
        let ingredient = Ingredient(
            name: "flaky salt",
            isToTaste: true,
            orderIndex: 0
        )

        XCTAssertEqual(ingredient.cookingDetailText(scaledBy: 2), "flaky salt")
    }

    /// The demo library is what a reviewer and a screenshot see, so it has
    /// to carry the shape the backend now sends.
    func testTheDemoLibraryReadsFromItsSplit() {
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

    /// Plain decimals, no unit conversion: four times 1½ tsp is 6 tsp, and
    /// the app does not decide that a cook would rather read a tablespoon.
    func testScalingNeverConvertsUnits() {
        let ingredient = Ingredient(
            normalizedQuantity: Decimal(string: "1.5"),
            unit: "tsp",
            name: "kosher salt",
            orderIndex: 0
        )

        XCTAssertEqual(
            ingredient.cookingDetailText(scaledBy: 4),
            "6 tsp kosher salt"
        )
    }

    /// A third of a cup is an amount somebody measures, so a scaled row
    /// keeps the two fraction digits `measuredAmount` renders rather than
    /// rounding to a tenth.
    func testAThirdOfARowKeepsTwoFractionDigits() {
        let ingredient = Ingredient(
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

    /// A row with an amount can be multiplied; a row that has none — the
    /// salt a cook seasons to taste — cannot, and the list marks it so the
    /// cook can see which line did not move.
    func testOnlyARowWithAnAmountIsScalable() {
        let beef = Ingredient(
            normalizedQuantity: 1,
            unit: "lb",
            name: "ground beef",
            orderIndex: 0
        )
        let salt = Ingredient(
            name: "kosher salt",
            isToTaste: true,
            orderIndex: 1
        )

        XCTAssertTrue(beef.isScalable)
        XCTAssertFalse(salt.isScalable)
    }

    /// A library stored before the split was guaranteed can hold a row with
    /// a unit and no number. It renders as its name, so it has nothing to
    /// multiply either, whatever the flag says.
    func testARowWithNoNumberIsNotScalable() {
        let ingredient = Ingredient(
            unit: "cups",
            name: "flour",
            orderIndex: 0
        )

        XCTAssertFalse(ingredient.isScalable)
        XCTAssertEqual(ingredient.cookingDetailText(scaledBy: 2), "flour")
    }

    /// The demo library is what a reviewer, a screenshot and the UI test
    /// see, so doubling it has to come out the way a cook would write it.
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
        // Half a small onion, doubled, is a whole one — and no ".00".
        XCTAssertEqual(
            smashBurgers.orderedIngredients[5].cookingDetailText(scaledBy: 2),
            "1 small white onion — shaved thin"
        )
        // The one row a multiplier cannot reach.
        XCTAssertEqual(
            smashBurgers.orderedIngredients[6].cookingDetailText(scaledBy: 2),
            "kosher salt"
        )
    }
}
