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
}
