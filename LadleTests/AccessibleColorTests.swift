import SwiftUI
import UIKit
import XCTest
@testable import Ladle

@MainActor
final class AccessibleColorTests: XCTestCase {
    func testActionLabelsMeetSmallTextContrastInEveryAppearance() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            for accent in LadleAccentColor.allCases {
                assertContrast(LadleTheme.Label.onAccent, accent.intent, traits: traits)
            }
            assertContrast(LadleTheme.Label.onAccent, LadleTheme.Intent.focusFill, traits: traits)
            assertContrast(LadleTheme.Label.onAccent, LadleTheme.Intent.destructiveFill, traits: traits)
        }
    }

    func testSupportingTextIsReadableOnEveryContentSurface() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            for surface in [LadleTheme.Surface.porcelain, LadleTheme.Surface.raised, LadleTheme.Surface.steel] {
                assertContrast(LadleTheme.Label.secondary, surface, traits: traits)
            }
        }
    }

    private func assertContrast(
        _ foreground: Color, _ background: Color, traits: UITraitCollection,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let first = luminance(UIColor(foreground).resolvedColor(with: traits))
        let second = luminance(UIColor(background).resolvedColor(with: traits))
        let ratio = (max(first, second) + 0.05) / (min(first, second) + 0.05)
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "Contrast \(ratio):1 in \(traits)", file: file, line: line)
    }

    private func luminance(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
