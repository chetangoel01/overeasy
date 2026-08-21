import SwiftUI

enum LadleTheme {
    // "Butter & Basil" palette. Legacy token names carry new roles:
    // plum = deep basil (Focus Mode, selected), paper = warm white,
    // oat = butter-light surfaces, butter = chrome band, brick = tomato,
    // celery = basil leaf, ube = pistachio wash, accentText = deep tomato.
    static let plumHex = "#2E4517"
    static let paperHex = "#FFFBEB"
    static let oatHex = "#FAF0C0"
    static let butterHex = "#F7E082"
    static let inkHex = "#253312"
    static let brickHex = "#C0391B"
    static let celeryHex = "#A3C46E"
    static let ubeHex = "#EDEFD6"
    static let mutedInkHex = "#6C6C4E"
    static let darkPaperHex = "#15190D"
    static let darkOatHex = "#231F0E"
    static let darkButterHex = "#2E290F"
    static let darkInkHex = "#F6F2DC"
    static let darkMutedInkHex = "#B8B694"
    static let darkUbeHex = "#20260F"
    static let darkCeleryHex = "#39491F"
    static let onAccentHex = "#FFFBEB"
    static let accentTextHex = "#A63A1B"
    static let darkAccentTextHex = "#FF9973"
    static let onYolkHex = "#253312"
    static let focusGoldHex = "#F6D95C"
    static let focusActionTextHex = plumHex

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
        red: 255 / 255,
        green: 251 / 255,
        blue: 235 / 255
    )
    // Fixed deep basil for text on fixed light fills in both appearances.
    static let onYolk = Color(
        red: 37 / 255,
        green: 51 / 255,
        blue: 18 / 255
    )
    // Fixed butter gold for accents on the basil Focus Mode ground.
    static let focusGold = Color(
        red: 246 / 255,
        green: 217 / 255,
        blue: 92 / 255
    )
    static let focusActionText = Color(
        red: 46 / 255,
        green: 69 / 255,
        blue: 23 / 255
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
