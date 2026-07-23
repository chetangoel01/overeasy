import XCTest
@testable import Ladle

final class DesignTokenTests: XCTestCase {
    func testEditorialPaletteUsesApprovedHexValues() {
        XCTAssertEqual(LadleTheme.paperHex, "#FBFAF7")
        XCTAssertEqual(LadleTheme.fieldHex, "#F1EEE8")
        XCTAssertEqual(LadleTheme.inkHex, "#1F1D1A")
        XCTAssertEqual(LadleTheme.paprikaHex, "#B44B24")
        XCTAssertEqual(LadleTheme.reviewHex, "#F6ECD9")
        XCTAssertEqual(LadleTheme.successHex, "#3D7A44")
    }

    func testSpacingScaleIncreasesPredictably() {
        XCTAssertEqual(LadleTheme.Spacing.compact, 8)
        XCTAssertEqual(LadleTheme.Spacing.regular, 16)
        XCTAssertEqual(LadleTheme.Spacing.generous, 24)
        XCTAssertEqual(LadleTheme.Spacing.cooking, 32)
    }

    func testCornerScaleSupportsControlsCardsAndSheets() {
        XCTAssertEqual(LadleTheme.Corner.control, 12)
        XCTAssertEqual(LadleTheme.Corner.card, 16)
        XCTAssertEqual(LadleTheme.Corner.sheet, 34)
    }
}
