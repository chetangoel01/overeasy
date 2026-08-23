import SwiftUI

enum LadleTheme {
    // Porcelain library surfaces, graphite Focus Mode, and a single signal-red
    // action color. Legacy token names remain while their semantic roles settle.
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
    static let brick = Color("Brick")
    static let celery = Color("Celery")
    static let ube = Color("Ube")
    static let mutedInk = Color("MutedInk")
    static let accentText = Color("AccentText")
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
    static let paprika = accentText
    static let review = ube
    static let success = celery

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
