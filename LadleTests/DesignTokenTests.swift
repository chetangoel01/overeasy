import XCTest
@testable import Ladle

final class DesignTokenTests: XCTestCase {
    func testMutedCornerStorePaletteUsesApprovedHexValues() {
        XCTAssertEqual(LadleTheme.plumHex, "#493943")
        XCTAssertEqual(LadleTheme.paperHex, "#FAF6EF")
        XCTAssertEqual(LadleTheme.oatHex, "#F1ECE3")
        XCTAssertEqual(LadleTheme.inkHex, "#30272D")
        XCTAssertEqual(LadleTheme.brickHex, "#AD503D")
        XCTAssertEqual(LadleTheme.celeryHex, "#BEC9AE")
        XCTAssertEqual(LadleTheme.ubeHex, "#DDD5DF")
        XCTAssertEqual(LadleTheme.mutedInkHex, "#72676D")
    }

    func testDarkPaletteStaysWarmAndKeepsAccentTextSeparate() {
        XCTAssertEqual(LadleTheme.darkPaperHex, "#1D191C")
        XCTAssertEqual(LadleTheme.darkOatHex, "#282226")
        XCTAssertEqual(LadleTheme.darkInkHex, "#F7F0E8")
        XCTAssertEqual(LadleTheme.darkMutedInkHex, "#B9ADB3")
        XCTAssertEqual(LadleTheme.darkUbeHex, "#332B31")
        XCTAssertEqual(LadleTheme.darkCeleryHex, "#364536")
        XCTAssertEqual(LadleTheme.onAccentHex, "#FFF9F0")
        XCTAssertEqual(LadleTheme.accentTextHex, "#AD503D")
        XCTAssertEqual(LadleTheme.darkAccentTextHex, "#E58A74")
        XCTAssertEqual(LadleTheme.focusActionTextHex, "#493943")
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
