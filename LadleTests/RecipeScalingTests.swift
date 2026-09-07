import Foundation
import LadleCore
import XCTest
@testable import Ladle

/// The cook-time serving count. It is a value the recipe page holds and
/// nothing more: the recipe keeps the yield it claims, nothing syncs, and
/// closing the page is the undo — which is why there is no "save" here to
/// test, only a `reset`.
final class RecipeScalingTests: XCTestCase {
    func testAFreshPageReadsTheRecipeAsWritten() {
        let scaling = RecipeScaling(baseServings: 4)

        XCTAssertEqual(scaling.servings, 4)
        XCTAssertFalse(scaling.isScaled)
        XCTAssertNil(scaling.multiplier)
    }

    func testTheChosenCountIsTheMultiplier() {
        var scaling = RecipeScaling(baseServings: 4)

        scaling.setServings(6)

        XCTAssertTrue(scaling.isScaled)
        XCTAssertEqual(scaling.multiplier, 1.5)
    }

    /// Choosing the count the recipe already claims is not scaling, and has
    /// to put every row back to the creator's own words.
    func testChoosingTheStoredYieldAgainIsNotScaling() {
        var scaling = RecipeScaling(baseServings: 4)

        scaling.setServings(8)
        scaling.setServings(4)

        XCTAssertFalse(scaling.isScaled)
        XCTAssertNil(scaling.multiplier)
    }

    func testTheCountStopsAtOneServing() {
        var scaling = RecipeScaling(baseServings: 4)

        scaling.setServings(0)

        XCTAssertEqual(scaling.servings, 1)
    }

    func testTheCountStopsAtTheContractMaximum() {
        var scaling = RecipeScaling(baseServings: 4)

        scaling.setServings(RecipeContractLimits.maximumServings + 1)

        XCTAssertEqual(scaling.servings, RecipeContractLimits.maximumServings)
    }

    func testResetReturnsToTheStoredYield() {
        var scaling = RecipeScaling(baseServings: 4)

        scaling.setServings(12)
        scaling.reset()

        XCTAssertEqual(scaling.servings, 4)
        XCTAssertNil(scaling.multiplier)
    }

    /// A recipe claiming no yield has nothing to scale from — the ratio would
    /// divide by zero — so the page withholds the control rather than
    /// showing one that cannot mean anything.
    func testARecipeWithNoYieldIsNotScalable() {
        var scaling = RecipeScaling(baseServings: 0)

        XCTAssertFalse(scaling.isAvailable)

        scaling.setServings(6)

        XCTAssertNil(scaling.multiplier)
        XCTAssertFalse(scaling.isScaled)
    }

    func testAStatedYieldOffersTheControl() {
        XCTAssertTrue(RecipeScaling(baseServings: 4).isAvailable)
    }
}
