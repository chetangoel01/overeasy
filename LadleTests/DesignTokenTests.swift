import LadleCore
import SwiftUI
import UIKit
import XCTest
@testable import Ladle

private extension UIColor {
    /// Relative luminance, used to assert that two surfaces are far enough
    /// apart to read as different.
    var luminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

@MainActor
final class DesignTokenTests: XCTestCase {
    func testProductionScreensUseSemanticColorRoles() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = project.appendingPathComponent("Ladle")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: nil
            )
        )
        let paletteNames = [
            "paper", "oat", "ube", "plum", "ink", "mutedInk",
            "onAccent", "fixedInk", "accentText", "brick", "celery",
            "focusAccent", "butter", "thyme",
        ]
        var offenders: [String] = []

        for case let file as URL in enumerator
        where file.pathExtension == "swift"
            && file.lastPathComponent != "LadleTheme.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let usedNames = paletteNames.filter {
                source.contains("LadleTheme.\($0)")
            }
            if !usedNames.isEmpty {
                let relativePath = file.path.replacingOccurrences(
                    of: project.path + "/",
                    with: ""
                )
                offenders.append("\(relativePath): \(usedNames.joined(separator: ", "))")
            }
        }

        XCTAssertEqual(offenders.sorted(), [])
    }

    func testControlTintsUseIntentAndDecorativeBulletsStayNeutral() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = try productionSwiftSources(
            under: project.appendingPathComponent("Ladle")
        )
        var offenders: [String] = []

        for file in sources {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains(".tint(accent.label)")
                || source.contains(".fill(accent.label)") {
                offenders.append(file.lastPathComponent)
            }
        }

        XCTAssertEqual(offenders.sorted(), [])
        let editor = try String(
            contentsOf: project.appendingPathComponent(
                "Ladle/Edit/RecipeEditorView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(editor.contains("? accent.intent"))
    }

    /// The accent may only be read out of storage in the two places that have
    /// a reason to: the root, which publishes it into the environment, and the
    /// picker, which writes it. Everywhere else reads
    /// `@Environment(\.ladleAccent)`.
    ///
    /// This is the regression guard for the bug that prompted the change. The
    /// accent used to be a theme property that read `UserDefaults` at
    /// body-evaluation time; SwiftUI has no dependency on `UserDefaults`, so
    /// changing the accent invalidated nothing and a screen only picked up the
    /// new colour when it re-rendered for some unrelated reason. A third
    /// storage reader would reintroduce exactly that.
    func testAccentIsReadFromStorageOnlyWhereItIsPublishedOrChosen() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = try productionSwiftSources(
            under: project.appendingPathComponent("Ladle")
        )

        let readers = try sources.filter { file in
            let source = try String(contentsOf: file, encoding: .utf8)
            return source.contains("LadleAccentColor.resolve(storedValue:")
        }
        .map(\.lastPathComponent)
        .sorted()

        XCTAssertEqual(
            readers,
            ["AccountSheet.swift", "LadleApp.swift"],
            "Only the root and the accent picker may resolve the accent from "
                + "storage; everything else reads the environment"
        )
    }

    func testProductionUsesNamedControlHeights() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoots = [
            project.appendingPathComponent("Ladle"),
            project.appendingPathComponent("LadleShare"),
        ]
        let rawPatterns = [
            ".frame(minHeight: 44)",
            ".frame(minHeight: 46)",
            ".frame(minHeight: 48)",
            ".frame(minHeight: 50)",
            ".frame(minHeight: 52)",
            ".frame(minHeight: 56)",
            ".frame(height: 52)",
            ".frame(width: 32, height: 44)",
            ".frame(width: 44, height: 44)",
        ]
        var offenders: [String] = []

        for root in sourceRoots {
            for file in try productionSwiftSources(under: root) {
                let source = try String(contentsOf: file, encoding: .utf8)
                let patterns = rawPatterns.filter(source.contains)
                if !patterns.isEmpty {
                    offenders.append(file.lastPathComponent)
                }
            }
        }

        XCTAssertEqual(offenders.sorted(), [])
    }

    func testProductionUsesNamedIconSizes() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoots = [
            project.appendingPathComponent("Ladle"),
            project.appendingPathComponent("LadleShare"),
        ]
        let rawIconSize = try NSRegularExpression(
            pattern: #"\.font\(\.system\(size: [0-9]"#
        )
        var offenders: [String] = []

        for root in sourceRoots {
            for file in try productionSwiftSources(under: root) {
                let source = try String(contentsOf: file, encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                if rawIconSize.firstMatch(in: source, range: range) != nil {
                    offenders.append(file.lastPathComponent)
                }
            }
        }

        XCTAssertEqual(offenders.sorted(), [])
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

    func testLayoutRolesResolveToStepsOnTheSpacingScale() {
        let scale: Set<CGFloat> = [
            LadleTheme.Spacing.tight,
            LadleTheme.Spacing.compact,
            LadleTheme.Spacing.medium,
            LadleTheme.Spacing.regular,
            LadleTheme.Spacing.generous,
            LadleTheme.Spacing.cooking,
        ]
        for role in [
            LadleTheme.Layout.screenMargin,
            LadleTheme.Layout.sheetMargin,
            LadleTheme.Layout.cardPadding,
            LadleTheme.Layout.sectionGap,
            LadleTheme.Layout.rowGap,
            LadleTheme.Layout.iconGap,
            LadleTheme.Layout.scrollTail,
        ] {
            XCTAssertTrue(
                scale.contains(role),
                "\(role) is not a step on the spacing scale"
            )
        }
        XCTAssertEqual(LadleTheme.Layout.screenMargin, 16)
        XCTAssertEqual(LadleTheme.Layout.sheetMargin, 24)
    }

    func testWatchOverlayLayoutUsesProvidedSafeAreaInsets() {
        // Top chrome is already inside the safe area, so it must not add the
        // inset again; only the bottom padding clears the home indicator.
        XCTAssertEqual(
            WatchOverlayLayout.topPadding,
            LadleTheme.Spacing.compact
        )
        XCTAssertEqual(
            WatchOverlayLayout.refreshTopPadding,
            LadleTheme.Spacing.compact + LadleTheme.Control.hitTarget
        )
        XCTAssertEqual(
            WatchOverlayLayout.bottomPadding(safeAreaBottom: 34),
            34 + LadleTheme.Control.primary
                + LadleTheme.Spacing.regular
        )
        XCTAssertNotEqual(
            WatchOverlayLayout.bottomPadding(safeAreaBottom: 0),
            WatchOverlayLayout.bottomPadding(safeAreaBottom: 34)
        )
    }

    func testControlHeightsCollapseToThreeNamedValues() {
        XCTAssertEqual(LadleTheme.Control.hitTarget, 44)
        XCTAssertEqual(LadleTheme.Control.field, 48)
        XCTAssertEqual(LadleTheme.Control.primary, 52)
    }

    func testDividerInsetIsDerivedFromTheRowItSeparates() {
        // The cooking checklist lays out a 30pt icon and a 13pt gap, so its
        // divider belongs at 43 - not the 52 that a differently built row uses.
        XCTAssertEqual(
            LadleTheme.dividerInset(iconWidth: 30, gap: 13),
            43
        )
        // Collections: 12pt leading padding, 28pt icon, 12pt gap.
        XCTAssertEqual(
            LadleTheme.dividerInset(
                iconWidth: 28,
                gap: 12,
                leadingPadding: 12
            ),
            52
        )
        XCTAssertEqual(
            LadleTheme.dividerInset(iconWidth: 28),
            28 + LadleTheme.Layout.iconGap
        )
    }

    func testButtonRolesCarryDistinctFillAndLabelIntent() {
        let accent = LadleAccentColor.tomato
        XCTAssertNotNil(LadleButtonRole.primary.fill(accent))
        XCTAssertNotNil(LadleButtonRole.secondary.fill(accent))
        XCTAssertNotNil(LadleButtonRole.destructive.fill(accent))
        XCTAssertNil(
            LadleButtonRole.tertiary.fill(accent),
            "A tertiary button carries no fill"
        )
        XCTAssertEqual(LadleButtonRole.destructive.fill(accent), LadleTheme.Intent.destructiveFill)
        XCTAssertEqual(
            LadleButtonRole.primary.label(accent),
            LadleTheme.Label.onAccent
        )
        XCTAssertEqual(
            LadleButtonRole.secondary.label(accent),
            LadleTheme.Label.primary
        )
    }

    /// The roles that carry the accent must actually follow it. This is the
    /// property the old implementation looked like it had and did not: the
    /// colour was read from `UserDefaults` at call time, so nothing observed
    /// a change. Taking the accent as an argument is what makes it testable
    /// at all.
    func testAccentBearingRolesFollowTheChosenAccent() {
        for other in LadleAccentColor.allCases where other != .tomato {
            XCTAssertNotEqual(
                LadleButtonRole.primary.fill(.tomato),
                LadleButtonRole.primary.fill(other),
                "A primary fill must differ between Tomato and \(other.title)"
            )
            XCTAssertNotEqual(
                LadleButtonRole.tertiary.label(.tomato),
                LadleButtonRole.tertiary.label(other),
                "A tertiary label must differ between Tomato and \(other.title)"
            )
            XCTAssertNotEqual(
                LadleIconButtonTone.primary.background(.tomato),
                LadleIconButtonTone.primary.background(other),
                "An icon button fill must differ between Tomato and \(other.title)"
            )
        }
    }

    /// The roles that do *not* carry the accent must be indifferent to it.
    func testNeutralRolesIgnoreTheAccent() {
        for accent in LadleAccentColor.allCases {
            XCTAssertEqual(LadleButtonRole.destructive.fill(accent), LadleTheme.Intent.destructiveFill)
            XCTAssertEqual(
                LadleButtonRole.secondary.fill(accent),
                LadleTheme.Surface.raised
            )
            XCTAssertEqual(
                LadleIconButtonTone.quiet.background(accent),
                LadleTheme.Surface.steel
            )
        }
    }

    func testDiscoverSaveKeepsItsBoundsWhileLoadingAtEveryTextSize() {
        for textSize: DynamicTypeSize in [.large, .accessibility3, .accessibility5] {
            let ready = discoverSaveSize(isSaving: false, textSize: textSize)
            let loading = discoverSaveSize(isSaving: true, textSize: textSize)
            XCTAssertEqual(ready.width, loading.width, accuracy: 0.5)
            XCTAssertEqual(ready.height, loading.height, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(ready.height, LadleTheme.Control.primary)
        }
    }

    private func discoverSaveSize(
        isSaving: Bool,
        textSize: DynamicTypeSize
    ) -> CGSize {
        let recipe = DiscoverRecipe(
            sourceID: UUID(), title: "Lemon Orzo", description: "",
            creatorName: nil, source: .tiktok,
            originalURL: URL(string: "https://www.tiktok.com/@cook/video/123")!,
            imageURL: nil, savedCount: 12
        )
        let row = DiscoverRecipeRow(
            recipe: recipe, sort: .popular, isLoadingDetail: false,
            isSaving: isSaving, isSaved: false,
            openFailure: nil, saveFailure: nil, open: {}, save: {}
        )
        let host = UIHostingController(
            rootView: row.saveButton.environment(\.dynamicTypeSize, textSize)
        )
        return host.sizeThatFits(in: CGSize(width: 390, height: 300))
    }

    /// Issue #140. Both strips sit in a top safe-area inset, so any height
    /// they take while work is merely in flight moves the whole screen.
    func testRoutineSyncAndRefreshTakeNoSpaceButFailuresDo() {
        let syncing = SyncStatus()
        syncing.begin()
        let failedSync = SyncStatus()
        failedSync.fail(APIError.transport)
        let failedRefresh = DiscoverViewModel.RefreshState.failed(
            RemoteFailureReport(APIError.transport)
        )

        XCTAssertEqual(topStripHeight(SyncStatusBanner(status: syncing)), 0)
        XCTAssertGreaterThan(
            topStripHeight(SyncStatusBanner(status: failedSync)), 0
        )
        XCTAssertEqual(
            topStripHeight(
                DiscoverRefreshBanner(state: .refreshing, retry: {})
            ),
            0
        )
        XCTAssertGreaterThan(
            topStripHeight(
                DiscoverRefreshBanner(state: failedRefresh, retry: {})
            ),
            0
        )
    }

    private func topStripHeight(_ strip: some View) -> CGFloat {
        UIHostingController(rootView: strip)
            .sizeThatFits(in: CGSize(width: 390, height: 300)).height
    }

    func testFilledButtonsShareOneWidthAndTertiaryHugsItsLabel() {
        XCTAssertTrue(LadleButtonStyle(role: .primary).isFullWidth)
        XCTAssertTrue(LadleButtonStyle(role: .secondary).isFullWidth)
        XCTAssertTrue(LadleButtonStyle(role: .destructive).isFullWidth)
        XCTAssertFalse(LadleButtonStyle(role: .tertiary).isFullWidth)
        XCTAssertTrue(
            LadleButtonStyle(role: .tertiary, isFullWidth: true).isFullWidth
        )
    }

    func testRecipeOptionsUseSemanticRolesWithoutIndentingRows() {
        // The options live in a native Menu, so destructive styling comes
        // from the system's button role rather than a filled CTA background.
        XCTAssertTrue(RecipeOption.delete.isDestructive)
        for option in [
            RecipeOption.edit,
            .reimport,
            .nutrition,
            .source,
        ] {
            XCTAssertFalse(
                option.isDestructive,
                "\(option) should remain a non-destructive action"
            )
        }
        XCTAssertEqual(
            LadleButtonStyle(role: .tertiary).horizontalPadding,
            LadleTheme.Spacing.regular
        )
        XCTAssertEqual(
            LadleButtonStyle(
                role: .tertiary,
                isFullWidth: true
            ).horizontalPadding,
            0,
            "A full-width row owns its own content inset"
        )
    }

    func testBadgeSurfaceIsDistinguishableFromTheCardBehindIt() {
        // Surface.steel sits about four percent off Surface.raised, which is
        // why a badge drawn in it disappears into the card. Surface.badge has
        // to separate further than that in both appearances.
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)

        for traits in [light, dark] {
            let raised = UIColor(LadleTheme.Surface.raised)
                .resolvedColor(with: traits)
            let steel = UIColor(LadleTheme.Surface.steel)
                .resolvedColor(with: traits)
            let badge = UIColor(LadleTheme.Surface.badge)
                .resolvedColor(with: traits)

            XCTAssertGreaterThan(
                abs(badge.luminance - raised.luminance),
                abs(steel.luminance - raised.luminance),
                "Surface.badge must separate from the card more than steel does"
            )
        }
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

    /// Every row in either picker carries its own symbol, so the icon column
    /// is never half empty. `RecipeSort` lives in LadleCore and holds no
    /// presentation, so its icons sit in the app-side extension beside
    /// `libraryTitle`.
    func testEveryPickerRowCarriesItsOwnSymbol() {
        let sortImages = RecipeSort.allCases.map(\.librarySystemImage)
        XCTAssertEqual(Set(sortImages).count, RecipeSort.allCases.count)
        XCTAssertFalse(sortImages.contains(where: \.isEmpty))
        XCTAssertFalse(sortImages.contains("checkmark"))

        let modeImages = LibraryDisplayMode.allCases.map(\.systemImage)
        XCTAssertEqual(
            Set(modeImages).count,
            LibraryDisplayMode.allCases.count
        )
        XCTAssertFalse(modeImages.contains(where: \.isEmpty))
        XCTAssertFalse(modeImages.contains("checkmark"))
        XCTAssertEqual(
            LibraryDisplayMode.allCases.map(\.title),
            ["Grid", "List", "Gallery"]
        )
    }

    private func productionSwiftSources(under root: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            )
        )
        return enumerator.compactMap { entry in
            guard
                let file = entry as? URL,
                file.pathExtension == "swift"
            else {
                return nil
            }
            return file
        }
    }
}
