import SwiftUI
import UIKit

enum LadleAccentColor: String, CaseIterable, Identifiable {
    case tomato
    case orange
    case sage
    case blue
    case purple

    static let preferenceKey = "ladle.appearance.accent-color"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tomato: "Tomato"
        case .orange: "Orange"
        case .sage: "Sage"
        case .blue: "Blue"
        case .purple: "Purple"
        }
    }

    var actionColor: Color {
        switch self {
        case .tomato:
            Color("Brick")
        case .orange:
            Self.dynamicColor(light: 0xB85C00, dark: 0xC76600)
        case .sage:
            Self.dynamicColor(light: 0x3C7650, dark: 0x47865C)
        case .blue:
            Self.dynamicColor(light: 0x2368AD, dark: 0x2A72BC)
        case .purple:
            Self.dynamicColor(light: 0x7652A7, dark: 0x805BB2)
        }
    }

    var textColor: Color {
        switch self {
        case .tomato:
            Color("AccentText")
        case .orange:
            Self.dynamicColor(light: 0xA75000, dark: 0xFFB36A)
        case .sage:
            Self.dynamicColor(light: 0x2F6B44, dark: 0x76C98C)
        case .blue:
            Self.dynamicColor(light: 0x1D5F9F, dark: 0x72B5FF)
        case .purple:
            Self.dynamicColor(light: 0x70489E, dark: 0xC8A7F5)
        }
    }

    static func resolve(storedValue: String?) -> Self {
        Self(rawValue: storedValue ?? "") ?? .tomato
    }

    private static func dynamicColor(light: Int, dark: Int) -> Color {
        Color(
            uiColor: UIColor { traits in
                UIColor(
                    rgb: traits.userInterfaceStyle == .dark ? dark : light
                )
            }
        )
    }
}

private extension UIColor {
    convenience init(rgb: Int) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum LadleTheme {
    // Porcelain library surfaces, graphite Focus Mode, and a configurable
    // action accent. Legacy token names remain while their semantic roles settle.
    static let plumHex = "#14181B"
    static let paperHex = "#F2F4F6"
    static let oatHex = "#E3E7EA"
    static let butterHex = "#D7DDE2"
    static let inkHex = "#14181B"
    static let brickHex = "#EE4B2F"
    static let celeryHex = "#83A18A"
    static let ubeHex = "#D7DDE2"
    static let mutedInkHex = "#64707A"
    static let darkPaperHex = "#101214"
    static let darkOatHex = "#1C2024"
    static let darkButterHex = "#252A2F"
    static let darkInkHex = "#F2F4F5"
    static let darkMutedInkHex = "#A6AFB7"
    static let darkUbeHex = "#252A2F"
    static let darkCeleryHex = "#294233"
    static let onAccentHex = "#FAFBFC"
    static let accentTextHex = "#C73924"
    static let darkAccentTextHex = "#FF7562"
    static let fixedInkHex = "#14181B"
    static let focusAccentHex = "#FF5A3D"

    static let plum = Color("Plum")
    static let paper = Color("Paper")
    static let oat = Color("Oat")
    static let butter = Color("Butter")
    static let ink = Color("Ink")
    static var brick: Color { selectedAccent.actionColor }
    static let celery = Color("Celery")
    static let ube = Color("Ube")
    static let mutedInk = Color("MutedInk")
    static var accentText: Color { selectedAccent.textColor }
    static let onAccent = Color(
        red: 250 / 255,
        green: 251 / 255,
        blue: 252 / 255
    )
    static let fixedInk = Color(
        red: 20 / 255,
        green: 24 / 255,
        blue: 27 / 255
    )
    static let focusAccent = Color(
        red: 255 / 255,
        green: 90 / 255,
        blue: 61 / 255
    )

    static let field = oat
    static var paprika: Color { accentText }
    static let review = ube
    static let success = celery

    private static var selectedAccent: LadleAccentColor {
        LadleAccentColor.resolve(
            storedValue: UserDefaults.standard.string(
                forKey: LadleAccentColor.preferenceKey
            )
        )
    }

    enum Spacing {
        static let tight: CGFloat = 4
        static let compact: CGFloat = 8
        static let medium: CGFloat = 12
        static let regular: CGFloat = 16
        static let generous: CGFloat = 24
        static let cooking: CGFloat = 32
    }

    enum Corner {
        static let control: CGFloat = 15
        static let card: CGFloat = 20
        static let sheet: CGFloat = 34
    }
}
