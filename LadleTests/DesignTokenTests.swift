import XCTest
@testable import Ladle

final class DesignTokenTests: XCTestCase {
    func testPorcelainPaletteUsesApprovedHexValues() {
        XCTAssertEqual(LadleTheme.plumHex, "#14181B")
        XCTAssertEqual(LadleTheme.paperHex, "#F2F4F6")
        XCTAssertEqual(LadleTheme.oatHex, "#E3E7EA")
        XCTAssertEqual(LadleTheme.butterHex, "#D7DDE2")
        XCTAssertEqual(LadleTheme.inkHex, "#14181B")
        XCTAssertEqual(LadleTheme.brickHex, "#EE4B2F")
        XCTAssertEqual(LadleTheme.celeryHex, "#83A18A")
        XCTAssertEqual(LadleTheme.ubeHex, "#D7DDE2")
        XCTAssertEqual(LadleTheme.mutedInkHex, "#64707A")
    }

    func testDarkPaletteUsesNeutralGraphiteSurfaces() {
        XCTAssertEqual(LadleTheme.darkPaperHex, "#101214")
        XCTAssertEqual(LadleTheme.darkOatHex, "#1C2024")
        XCTAssertEqual(LadleTheme.darkButterHex, "#252A2F")
        XCTAssertEqual(LadleTheme.darkInkHex, "#F2F4F5")
        XCTAssertEqual(LadleTheme.darkMutedInkHex, "#A6AFB7")
        XCTAssertEqual(LadleTheme.darkUbeHex, "#252A2F")
        XCTAssertEqual(LadleTheme.darkCeleryHex, "#294233")
        XCTAssertEqual(LadleTheme.onAccentHex, "#FAFBFC")
        XCTAssertEqual(LadleTheme.accentTextHex, "#C73924")
        XCTAssertEqual(LadleTheme.darkAccentTextHex, "#FF7562")
        XCTAssertEqual(LadleTheme.fixedInkHex, "#14181B")
        XCTAssertEqual(LadleTheme.focusAccentHex, "#FF5A3D")
    }

    func testAccentPreferenceHasStableChoicesAndFallback() {
        XCTAssertEqual(
            LadleAccentColor.allCases.map(\.rawValue),
            ["tomato", "orange", "sage", "blue", "purple"]
        )
        XCTAssertEqual(
            LadleAccentColor.resolve(storedValue: "blue"),
            .blue
        )
        XCTAssertEqual(
            LadleAccentColor.resolve(storedValue: "unknown"),
            .tomato
        )
        XCTAssertEqual(
            LadleAccentColor.resolve(storedValue: nil),
            .tomato
        )
    }

    func testSpacingScaleIncreasesPredictably() {
        XCTAssertEqual(LadleTheme.Spacing.compact, 8)
        XCTAssertEqual(LadleTheme.Spacing.regular, 16)
        XCTAssertEqual(LadleTheme.Spacing.generous, 24)
        XCTAssertEqual(LadleTheme.Spacing.cooking, 32)
    }

    func testCornerScaleSupportsControlsCardsAndSheets() {
        XCTAssertEqual(LadleTheme.Corner.control, 15)
        XCTAssertEqual(LadleTheme.Corner.card, 20)
        XCTAssertEqual(LadleTheme.Corner.sheet, 34)
    }

    func testPressMotionUsesApprovedZeroBounceTimingLanguage() {
        XCTAssertEqual(LadlePressKind.card.scale, 0.97)
        XCTAssertEqual(LadlePressKind.card.duration, 0.18)
        XCTAssertEqual(LadlePressKind.control.scale, 0.94)
        XCTAssertEqual(LadlePressKind.control.duration, 0.15)
    }

    func testFeedbackPolicyOnlyAcknowledgesMeaningfulStateChanges() {
        XCTAssertTrue(
            LadleFeedbackPolicy.didPush(from: 0, to: 1)
        )
        XCTAssertFalse(
            LadleFeedbackPolicy.didPush(from: 1, to: 0)
        )
        XCTAssertFalse(
            LadleFeedbackPolicy.didPush(from: 1, to: 1)
        )

        XCTAssertTrue(
            LadleFeedbackPolicy.didComplete(from: false, to: true)
        )
        XCTAssertFalse(
            LadleFeedbackPolicy.didComplete(from: true, to: false)
        )
        XCTAssertTrue(
            LadleFeedbackPolicy.didFinishReview(
                wasPending: true,
                isPending: false
            )
        )
    }

    func testTimerFeedbackIgnoresIdleAndRepeatedPhaseChanges() {
        XCTAssertEqual(
            LadleFeedbackPolicy.timerFeedback(
                from: .idle,
                to: .running
            ),
            .started
        )
        XCTAssertEqual(
            LadleFeedbackPolicy.timerFeedback(
                from: .running,
                to: .paused
            ),
            .paused
        )
        XCTAssertEqual(
            LadleFeedbackPolicy.timerFeedback(
                from: .running,
                to: .finished
            ),
            .finished
        )
        XCTAssertNil(
            LadleFeedbackPolicy.timerFeedback(
                from: .running,
                to: .running
            )
        )
        XCTAssertNil(
            LadleFeedbackPolicy.timerFeedback(
                from: .finished,
                to: .idle
            )
        )
    }

    func testReviewCompletionShowsReviewedBeforePromptNavigation() {
        var presentation = ReviewCompletionPresentation()

        XCTAssertEqual(presentation.title, "Mark reviewed")
        XCTAssertNil(presentation.systemImage)
        XCTAssertFalse(presentation.isReviewed)

        presentation.markReviewed()

        XCTAssertEqual(presentation.title, "Reviewed")
        XCTAssertEqual(presentation.systemImage, "checkmark")
        XCTAssertTrue(presentation.isReviewed)
        XCTAssertEqual(
            ReviewCompletionPresentation.navigationDelay(
                reduceMotion: false
            ),
            .milliseconds(160)
        )
        XCTAssertLessThanOrEqual(
            ReviewCompletionPresentation.navigationDelay(
                reduceMotion: false
            ),
            .milliseconds(180)
        )
        XCTAssertEqual(
            ReviewCompletionPresentation.navigationDelay(
                reduceMotion: true
            ),
            .zero
        )
    }
}
