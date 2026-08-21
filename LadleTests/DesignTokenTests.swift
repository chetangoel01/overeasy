import XCTest
@testable import Ladle

final class DesignTokenTests: XCTestCase {
    func testButterAndBasilPaletteUsesApprovedHexValues() {
        XCTAssertEqual(LadleTheme.plumHex, "#2E4517")
        XCTAssertEqual(LadleTheme.paperHex, "#FFFBEB")
        XCTAssertEqual(LadleTheme.oatHex, "#FAF0C0")
        XCTAssertEqual(LadleTheme.butterHex, "#F7E082")
        XCTAssertEqual(LadleTheme.inkHex, "#253312")
        XCTAssertEqual(LadleTheme.brickHex, "#C0391B")
        XCTAssertEqual(LadleTheme.celeryHex, "#A3C46E")
        XCTAssertEqual(LadleTheme.ubeHex, "#EDEFD6")
        XCTAssertEqual(LadleTheme.mutedInkHex, "#6C6C4E")
    }

    func testDarkPaletteStaysWarmAndKeepsAccentTextSeparate() {
        XCTAssertEqual(LadleTheme.darkPaperHex, "#15190D")
        XCTAssertEqual(LadleTheme.darkOatHex, "#231F0E")
        XCTAssertEqual(LadleTheme.darkButterHex, "#2E290F")
        XCTAssertEqual(LadleTheme.darkInkHex, "#F6F2DC")
        XCTAssertEqual(LadleTheme.darkMutedInkHex, "#B8B694")
        XCTAssertEqual(LadleTheme.darkUbeHex, "#20260F")
        XCTAssertEqual(LadleTheme.darkCeleryHex, "#39491F")
        XCTAssertEqual(LadleTheme.onAccentHex, "#FFFBEB")
        XCTAssertEqual(LadleTheme.accentTextHex, "#A63A1B")
        XCTAssertEqual(LadleTheme.darkAccentTextHex, "#FF9973")
        XCTAssertEqual(LadleTheme.onYolkHex, "#253312")
        XCTAssertEqual(LadleTheme.focusGoldHex, "#F6D95C")
        XCTAssertEqual(LadleTheme.focusActionTextHex, "#2E4517")
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
