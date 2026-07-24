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
}
