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
    // Palette values are private vocabulary for the semantic roles below.
    // Production screens consume Surface, Label, Intent, and Stroke instead.
    static let plumHex = "#14181B"
    static let paperHex = "#F7F4EF"
    static let oatHex = "#ECE7E1"
    static let inkHex = "#14181B"
    static let brickHex = "#EE4B2F"
    static let celeryHex = "#83A18A"
    static let ubeHex = "#E3DDD6"
    static let mutedInkHex = "#64707A"
    static let darkPaperHex = "#101214"
    static let darkOatHex = "#1C2024"
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

    // MARK: - Semantic roles
    //
    // The names above are the original palette names and say what a colour
    // *is*. The roles below say what a colour is *for*, which is the only
    // thing a call site should need to know. Call sites use these. The
    // palette names above remain because the roles are defined in terms of
    // them; the four alias pairs that used to sit between the two are gone.

    /// Backgrounds, from the page ground upward.
    enum Surface {
        /// The page ground. Food photography sits on this.
        static let porcelain = LadleTheme.paper
        /// Fields, grouped rows, and quiet cards on top of `porcelain`.
        static let raised = LadleTheme.oat
        /// Inactive and review surfaces.
        static let steel = LadleTheme.ube
        /// The graphite ground used by Welcome and Focus Mode.
        static let graphite = LadleTheme.plum
        /// Fill for a small icon badge sitting on a `raised` card.
        ///
        /// `steel` is only about four percent off `raised`, so a badge drawn
        /// in it disappears into the card behind it. This role is separated
        /// far enough to read as a badge at 34 points.
        static let badge = dynamicColor(light: 0xDCD5CC, dark: 0x303840)
    }

    /// Foregrounds. Each one names the surface it is legible on.
    enum Label {
        /// Primary text and controls on `porcelain` or `raised`.
        static let primary = LadleTheme.ink
        /// Metadata and supporting text on `porcelain` or `raised`.
        static let secondary = LadleTheme.mutedInk
        /// Text on an accent fill, or on `graphite`.
        static let onAccent = LadleTheme.onAccent
        /// Text on a surface that stays pale in both appearances.
        static let onFixedPale = LadleTheme.fixedInk
        /// Tinted text and icons that must still pass small-text contrast.
        static var accent: Color { LadleTheme.accentText }
    }

    /// Colours that carry meaning. Nothing here may be used for decoration:
    /// an accent-coloured creator handle or bullet is a misuse of this layer.
    enum Intent {
        /// Primary actions, favourites, active navigation, attention badges.
        static var accent: Color { LadleTheme.brick }
        /// Destructive actions. The system role, so it matches the platform's
        /// own delete affordances.
        static let destructive = Color.red
        /// Success and completion.
        static let success = LadleTheme.celery
        /// Focus Mode progress and advance, fixed across appearances.
        static let focus = LadleTheme.focusAccent
        /// Fill behind a disabled control. A disabled control loses its accent
        /// entirely rather than wearing a faded version of it.
        static let disabledFill = LadleTheme.ube
        /// Label on a disabled control.
        static let disabledLabel = LadleTheme.mutedInk
    }

    /// Hairlines and separators.
    enum Stroke {
        static var separator: Color { LadleTheme.ink.opacity(0.1) }
    }

    static func dynamicColor(light: Int, dark: Int) -> Color {
        Color(
            uiColor: UIColor { traits in
                UIColor(
                    rgb: traits.userInterfaceStyle == .dark ? dark : light
                )
            }
        )
    }

    private static var selectedAccent: LadleAccentColor {
        LadleAccentColor.resolve(
            storedValue: UserDefaults.standard.string(
                forKey: LadleAccentColor.preferenceKey
            )
        )
    }

    /// The only spacing steps the app may use. Any padding or stack spacing
    /// that is not one of these six values is a bug; see `Layout` first for a
    /// role that already names the value you want.
    enum Spacing {
        static let tight: CGFloat = 4
        static let compact: CGFloat = 8
        static let medium: CGFloat = 12
        static let regular: CGFloat = 16
        static let generous: CGFloat = 24
        static let cooking: CGFloat = 32
    }

    /// Spacing steps bound to the place they are used. Prefer these over the
    /// raw `Spacing` steps: a screen margin and a card's inner padding are both
    /// 16, but they are different decisions and should read differently.
    enum Layout {
        /// Leading and trailing margin for a workspace screen's content.
        static let screenMargin = Spacing.regular
        /// Leading and trailing margin for content inside a sheet, including
        /// the sheet's own toolbar control.
        static let sheetMargin = Spacing.generous
        /// Extra inset that moves a native toolbar item from the system's
        /// 16-point edge onto the 24-point sheet content margin.
        static let sheetToolbarInset = sheetMargin - screenMargin
        /// Inner padding for a grouped card or field.
        static let cardPadding = Spacing.regular
        /// Gap between two sections of a screen.
        static let sectionGap = Spacing.generous
        /// Gap between sibling rows in a list or stack.
        static let rowGap = Spacing.medium
        /// Gap between an icon and the label it introduces.
        static let iconGap = Spacing.medium
        /// Breathing room after the last thing in a scroll view.
        ///
        /// Six screens each invented their own value between 30 and 48 for
        /// this. On a tab screen the system already insets for the floating
        /// bar, so this sits on top of that rather than replacing it.
        static let scrollTail = Spacing.cooking
    }

    /// Control heights and hit targets. Three values only — a 46, 50 or 56
    /// point control is one of these three rounded by hand.
    enum Control {
        /// Minimum interactive target. Never smaller, including icon-only
        /// controls whose glyph is much smaller than the target.
        static let hitTarget: CGFloat = 44
        /// Text fields, search fields, and tappable list rows.
        static let field: CGFloat = 48
        /// Filled primary, secondary and destructive buttons.
        static let primary: CGFloat = 52
    }

    enum Corner {
        static let control: CGFloat = 15
        static let card: CGFloat = 20
        static let sheet: CGFloat = 34
        /// Small artwork (list thumbnails, inline marks) where `card` reads as
        /// too round for the size.
        static let thumbnail: CGFloat = 12
    }

    /// Symbol point sizes. The app had sixteen distinct ad-hoc sizes before
    /// these five roles existed.
    enum IconSize {
        /// Inline with metadata text.
        static let small: CGFloat = 13
        /// The default glyph inside a control.
        static let medium: CGFloat = 16
        /// A prominent control or a row's leading icon.
        static let large: CGFloat = 20
        /// The mark in a state view or an illustration.
        static let feature: CGFloat = 28
        /// The mark in a full-screen empty state.
        static let hero: CGFloat = 38
    }

    /// Leading inset for a divider that separates rows carrying a leading
    /// icon. Derive it — never hardcode — so the divider cannot drift away
    /// from the label it is separating when the icon or gap changes.
    ///
    /// - Parameters:
    ///   - iconWidth: Width of the row's leading icon frame.
    ///   - gap: Space between that icon and the label.
    ///   - leadingPadding: The row's own leading padding, if the divider is
    ///     laid out inside that padding rather than outside it.
    static func dividerInset(
        iconWidth: CGFloat,
        gap: CGFloat = Layout.iconGap,
        leadingPadding: CGFloat = 0
    ) -> CGFloat {
        leadingPadding + iconWidth + gap
    }
}
