import SwiftUI

/// The three `LadleTheme` roles a cooking timer needs on the Lock Screen.
///
/// `LadleTheme` is app-only and this is a separate module, so the roles are
/// restated here against the same values rather than reached for. Only
/// `Plum` is copied into this target's catalogue; the other two are fixed
/// literals in `LadleTheme` as well, so nothing else has to be duplicated.
/// Changing a value here without changing its twin in `LadleTheme` is a bug.
enum TimerActivityPalette {
    /// `Surface.graphite` — the ground Focus Mode already cooks on, and the
    /// activity's background tint.
    static let background = Color("Plum")

    /// `Label.onAccent` — content on graphite.
    static let label = Color(
        red: 250 / 255,
        green: 251 / 255,
        blue: 252 / 255
    )

    /// `Label.onAccent` at the weight Focus Mode gives its metadata.
    static var secondaryLabel: Color { label.opacity(0.82) }

    /// `Intent.focus` — Focus Mode's progress signal, fixed across
    /// appearances. The cook's chosen accent is app-only preference state and
    /// v1 shares no app group, so the activity wears the fixed signal.
    static let signal = Color(
        red: 255 / 255,
        green: 90 / 255,
        blue: 61 / 255
    )
}
