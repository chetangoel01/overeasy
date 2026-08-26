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
    func testProductionHasNoLegacyPrimaryButtonWrapper() throws {
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
        var offenders: [String] = []

        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("LadlePrimaryButtonStyle") {
                offenders.append(file.path.replacingOccurrences(
                    of: project.path + "/",
                    with: ""
                ))
            }
        }

        XCTAssertEqual(offenders.sorted(), [])
    }

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
            "focusAccent", "butter",
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

    func testShareUsesSemanticSurfaceNames() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: project.appendingPathComponent(
                "LadleShare/ShareConfirmationView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("ShareTheme.field"))
        XCTAssertFalse(source.contains("ShareTheme.review"))
        XCTAssertTrue(source.contains("ShareTheme.Surface.raised"))
        XCTAssertTrue(source.contains("ShareTheme.Surface.steel"))
    }

    func testCompatibilityColorAssetsAreRemoved() {
        let assets = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Ladle/Resources/Assets.xcassets")
        let compatibilityAssets = [
            "Butter", "Field", "Paprika", "Review", "Success",
        ]

        for name in compatibilityAssets {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: assets
                        .appendingPathComponent("\(name).colorset")
                        .path
                ),
                "\(name) is a retired compatibility asset"
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: assets
                    .appendingPathComponent("AccentColor.colorset")
                    .path
            ),
            "Xcode consumes AccentColor by catalog name"
        )
    }

    func testRaisedCardBadgesUseTheDistinctBadgeSurface() throws {
        let expectedCounts = [
            "Ladle/Account/AccountSheet.swift": 4,
            "Ladle/Account/GuestLimitView.swift": 1,
            "Ladle/Edit/ReimportSheet.swift": 2,
            "Ladle/Health/HealthExportSheet.swift": 1,
            "Ladle/Import/AddRecipeSheet.swift": 4,
            "Ladle/Import/FailedImportSheet.swift": 1,
        ]
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for (path, expectedCount) in expectedCounts {
            let source = try String(
                contentsOf: project.appendingPathComponent(path),
                encoding: .utf8
            )
            let count = source.components(
                separatedBy: "LadleTheme.Surface.badge, in: Circle()"
            ).count - 1
            XCTAssertEqual(count, expectedCount, path)
        }
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
            if source.contains(".tint(LadleTheme.Label.accent)")
                || source.contains(".fill(LadleTheme.Label.accent)") {
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
        XCTAssertTrue(editor.contains("? LadleTheme.Intent.accent"))
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

    func testPorcelainPaletteUsesApprovedHexValues() {
        XCTAssertEqual(LadleTheme.plumHex, "#14181B")
        XCTAssertEqual(LadleTheme.paperHex, "#F2F4F6")
        XCTAssertEqual(LadleTheme.oatHex, "#E3E7EA")
        XCTAssertEqual(LadleTheme.inkHex, "#14181B")
        XCTAssertEqual(LadleTheme.brickHex, "#EE4B2F")
        XCTAssertEqual(LadleTheme.celeryHex, "#83A18A")
        XCTAssertEqual(LadleTheme.ubeHex, "#D7DDE2")
        XCTAssertEqual(LadleTheme.mutedInkHex, "#64707A")
    }

    func testDarkPaletteUsesNeutralGraphiteSurfaces() {
        XCTAssertEqual(LadleTheme.darkPaperHex, "#101214")
        XCTAssertEqual(LadleTheme.darkOatHex, "#1C2024")
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
        XCTAssertEqual(LadleTheme.Corner.thumbnail, 12)
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

    func testSheetToolbarInsetCompletesTheSheetMargin() {
        XCTAssertEqual(
            LadleTheme.Layout.sheetToolbarInset,
            LadleTheme.Layout.sheetMargin
                - LadleTheme.Layout.screenMargin
        )
        XCTAssertEqual(LadleTheme.Layout.sheetToolbarInset, 8)
    }

    func testWatchOverlayLayoutUsesProvidedSafeAreaInsets() {
        XCTAssertEqual(
            WatchOverlayLayout.topPadding(safeAreaTop: 59),
            59 + LadleTheme.Spacing.compact
        )
        XCTAssertEqual(
            WatchOverlayLayout.refreshTopPadding(safeAreaTop: 59),
            59 + LadleTheme.Spacing.compact
                + LadleTheme.Control.hitTarget
        )
        XCTAssertEqual(
            WatchOverlayLayout.bottomPadding(safeAreaBottom: 34),
            34 + LadleTheme.Control.primary
                + LadleTheme.Spacing.regular
        )
        XCTAssertNotEqual(
            WatchOverlayLayout.topPadding(safeAreaTop: 0),
            WatchOverlayLayout.topPadding(safeAreaTop: 59)
        )
    }

    func testSheetToolbarControlsUseTheSemanticInset() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sheetSources = [
            "Ladle/Account/AccountSheet.swift",
            "Ladle/Edit/RecipeEditorView.swift",
            "Ladle/Edit/ReimportSheet.swift",
            "Ladle/Health/HealthExportSheet.swift",
            "Ladle/Import/AddRecipeSheet.swift",
            "Ladle/Import/CorrectionNotesView.swift",
            "Ladle/Import/FailedImportSheet.swift",
            "Ladle/Library/FilterSheet.swift",
            "Ladle/Library/VideoEmbedSheet.swift",
            "Ladle/Nutrition/NutritionView.swift",
            "Ladle/RecipeDetail/RecipeOptionsSheet.swift",
        ]
        var offenders: [String] = []

        for path in sheetSources {
            let source = try String(
                contentsOf: project.appendingPathComponent(path),
                encoding: .utf8
            )
            if !source.contains("LadleTheme.Layout.sheetToolbarInset") {
                offenders.append(path)
            }
        }

        XCTAssertEqual(offenders, [])
    }

    func testRecipeEditorUsesTheSheetMargin() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: project.appendingPathComponent(
                "Ladle/Edit/RecipeEditorView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("LadleTheme.Layout.sheetMargin"))
        XCTAssertFalse(
            source.contains(".padding(LadleTheme.Spacing.regular)")
        )
    }

    func testControlHeightsCollapseToThreeNamedValues() {
        XCTAssertEqual(LadleTheme.Control.hitTarget, 44)
        XCTAssertEqual(LadleTheme.Control.field, 48)
        XCTAssertEqual(LadleTheme.Control.primary, 52)
    }

    func testIconSizeScaleIsOrdered() {
        XCTAssertEqual(
            [
                LadleTheme.IconSize.small,
                LadleTheme.IconSize.medium,
                LadleTheme.IconSize.large,
                LadleTheme.IconSize.feature,
                LadleTheme.IconSize.hero,
            ],
            [13, 16, 20, 28, 38]
        )
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
        XCTAssertNotNil(LadleButtonRole.primary.fill)
        XCTAssertNotNil(LadleButtonRole.secondary.fill)
        XCTAssertNotNil(LadleButtonRole.destructive.fill)
        XCTAssertNil(
            LadleButtonRole.tertiary.fill,
            "A tertiary button carries no fill"
        )
        XCTAssertEqual(LadleButtonRole.destructive.fill, Color.red)
        XCTAssertEqual(
            LadleButtonRole.primary.label,
            LadleTheme.Label.onAccent
        )
        XCTAssertEqual(
            LadleButtonRole.secondary.label,
            LadleTheme.Label.primary
        )
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
        XCTAssertEqual(
            RecipeOption.delete.buttonRole.fill,
            LadleTheme.Intent.destructive
        )
        for option in [
            RecipeOption.edit,
            .reimport,
            .nutrition,
            .source,
        ] {
            XCTAssertNil(
                option.buttonRole.fill,
                "\(option) should remain a tertiary action"
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
