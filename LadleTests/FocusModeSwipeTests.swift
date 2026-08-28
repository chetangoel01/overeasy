import CoreGraphics
import XCTest
@testable import Ladle

final class FocusModeSwipeTests: XCTestCase {
    // MARK: - Vertical scrolling must never change the step

    func testVerticalScrollWithLeftwardDriftIsNotASwipe() {
        // A one-handed thumb scroll pivots at the thumb base and arcs:
        // ~200pt of vertical travel with ~50pt of leftward drift. This
        // must scroll the step content, not advance the step — and on
        // the last step it must not throw the cook out of Focus Mode.
        XCTAssertNil(
            FocusModeSwipe(
                translation: CGSize(width: -50, height: -200)
            ),
            "A vertical scroll drifting left must not read as a next-step swipe"
        )
    }

    func testVerticalScrollWithRightwardDriftIsNotASwipe() {
        XCTAssertNil(
            FocusModeSwipe(
                translation: CGSize(width: 50, height: 200)
            ),
            "A vertical scroll drifting right must not read as a previous-step swipe"
        )
    }

    func testPerfectDiagonalIsNotASwipe() {
        XCTAssertNil(
            FocusModeSwipe(
                translation: CGSize(width: -100, height: -100)
            ),
            "An ambiguous 45-degree drag must not change the step"
        )
        XCTAssertNil(
            FocusModeSwipe(
                translation: CGSize(width: 100, height: 100)
            )
        )
    }

    // MARK: - Deliberate horizontal swipes still work

    func testPredominantlyHorizontalLeftSwipeMovesToNextStep() {
        XCTAssertEqual(
            FocusModeSwipe(
                translation: CGSize(width: -120, height: -20)
            ),
            .nextStep
        )
    }

    func testPredominantlyHorizontalRightSwipeMovesToPreviousStep() {
        XCTAssertEqual(
            FocusModeSwipe(
                translation: CGSize(width: 120, height: 20)
            ),
            .previousStep
        )
    }

    // MARK: - Minimum travel boundary

    func testHorizontalTravelAtOrBelowMinimumIsNotASwipe() {
        XCTAssertNil(
            FocusModeSwipe(
                translation: CGSize(width: -FocusModeSwipe.minimumTravel, height: 0)
            ),
            "Exactly the minimum travel must not trigger"
        )
        XCTAssertNil(
            FocusModeSwipe(translation: CGSize(width: -10, height: -5))
        )
        XCTAssertNil(FocusModeSwipe(translation: .zero))
    }

    func testHorizontalTravelJustPastMinimumIsASwipe() {
        XCTAssertEqual(
            FocusModeSwipe(translation: CGSize(width: -45, height: 0)),
            .nextStep
        )
        XCTAssertEqual(
            FocusModeSwipe(translation: CGSize(width: 45, height: 0)),
            .previousStep
        )
    }
}
