import SwiftUI

/// The app's type roles, each mapped onto a system text style.
///
/// Sizes are iOS's, not ours: a role names *what the text is for* and the
/// platform decides how big that is. This is why the app tracks the system
/// at every Dynamic Type setting instead of only approximating it at the
/// default one, and why headings match the metrics of every other iOS app.
///
/// Use a role, not a size. `ladleScaledFont(size:)` exists for the rare case
/// where a cooking surface needs distance legibility beyond `display`, and for
/// nothing else. Symbol sizes live in `LadleTheme.IconSize`.
enum LadleTextStyle {
    /// A welcome or Focus Mode headline that owns the screen.
    case display
    /// A screen title, or a cooking instruction.
    case title
    /// A recipe's name wherever it appears as content.
    ///
    /// Content, so it scales on `title3` and grows with the reader's size.
    /// `section` is chrome and stays on `headline`, closer to the surrounding
    /// UI; the two diverge at large Dynamic Type, which is intended.
    case recipeTitle
    /// A section heading above a group of rows.
    case section
    /// Running text.
    case body
    /// Running text carrying emphasis, and every button label.
    case bodyStrong
    /// Counts, timestamps, source names, supporting detail. Always paired
    /// with `LadleTheme.Label.secondary`.
    case metadata
    /// A short uppercase label above a title, used only in Focus Mode.
    case eyebrow

    var textStyle: Font.TextStyle {
        switch self {
        case .display: .largeTitle
        case .title: .title
        case .recipeTitle: .title3
        case .section: .headline
        case .body, .bodyStrong: .body
        case .metadata: .footnote
        case .eyebrow: .caption
        }
    }

    /// `nil` keeps the text style's own weight, which matters for `headline`:
    /// iOS already sets it semibold, and restating that here would freeze it
    /// if the platform ever changes.
    var weight: Font.Weight? {
        switch self {
        case .display, .title: .bold
        case .recipeTitle: .semibold
        case .section: nil
        case .bodyStrong: .semibold
        case .body, .metadata: nil
        case .eyebrow: .semibold
        }
    }

    var width: Font.Width {
        .standard
    }

    var design: Font.Design {
        .default
    }
}

private struct LadleScaledFontModifier: ViewModifier {
    @ScaledMetric private var scaledSize: CGFloat

    private let weight: Font.Weight
    private let width: Font.Width
    private let design: Font.Design

    init(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: Font.Weight,
        width: Font.Width,
        design: Font.Design = .default
    ) {
        _scaledSize = ScaledMetric(
            wrappedValue: size,
            relativeTo: textStyle
        )
        self.weight = weight
        self.width = width
        self.design = design
    }

    func body(content: Content) -> some View {
        content
            .font(
                .system(
                    size: scaledSize,
                    weight: weight,
                    design: design
                )
            )
            .fontWidth(width)
    }
}

extension View {
    func ladleFont(_ style: LadleTextStyle) -> some View {
        font(
            .system(
                style.textStyle,
                design: style.design,
                weight: style.weight
            )
        )
        .fontWidth(style.width)
    }

    func ladleScaledFont(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: Font.Weight = .regular,
        width: Font.Width = .standard,
        design: Font.Design = .default
    ) -> some View {
        modifier(
            LadleScaledFontModifier(
                size: size,
                relativeTo: textStyle,
                weight: weight,
                width: width,
                design: design
            )
        )
    }
}
