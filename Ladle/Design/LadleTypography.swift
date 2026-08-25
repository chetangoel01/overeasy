import SwiftUI

/// The app's type roles. All of them use SF Pro at standard width and design;
/// the system is carried by size and weight, not by a second typeface.
///
/// Use a role, not a size. `ladleScaledFont(size:)` exists for the rare case
/// where a cooking surface needs distance legibility beyond `display`, and for
/// nothing else. Symbol sizes live in `LadleTheme.IconSize`.
enum LadleTextStyle {
    /// A welcome or Focus Mode headline that owns the screen. 38pt, bold.
    case display
    /// A screen title, or a cooking instruction. 31pt, bold.
    case title
    /// A recipe's name wherever it appears as content. 18pt, semibold.
    ///
    /// Deliberately distinct from `section` despite being one point apart:
    /// this scales against `.title3` because a recipe name is content and
    /// should grow with the user's reading size, while `section` scales
    /// against `.headline` because a section label is chrome and should stay
    /// closer to the surrounding UI. They diverge at large Dynamic Type.
    case recipeTitle
    /// A section heading above a group of rows. 19pt, semibold.
    case section
    /// Running text. 17pt, regular.
    case body
    /// Running text carrying emphasis, and every button label. 17pt, semibold.
    case bodyStrong
    /// Counts, timestamps, source names, supporting detail. 13pt, regular,
    /// and always paired with `LadleTheme.Label.secondary`.
    case metadata
    /// A short uppercase label above a title, used only in Focus Mode.
    case eyebrow

    var baseSize: CGFloat {
        switch self {
        case .display:
            38
        case .title:
            31
        case .recipeTitle:
            18
        case .section:
            19
        case .body, .bodyStrong:
            17
        case .metadata:
            13
        case .eyebrow:
            12
        }
    }

    var relativeTextStyle: Font.TextStyle {
        switch self {
        case .display:
            .largeTitle
        case .title:
            .title
        case .recipeTitle:
            .title3
        case .section:
            .headline
        case .body, .bodyStrong:
            .body
        case .metadata:
            .footnote
        case .eyebrow:
            .caption
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display, .title:
            .bold
        case .recipeTitle, .section:
            .semibold
        case .bodyStrong:
            .semibold
        case .body:
            .regular
        case .metadata:
            .regular
        case .eyebrow:
            .semibold
        }
    }

    var width: Font.Width {
        .standard
    }

    var design: Font.Design {
        .default
    }
}

private struct LadleFontModifier: ViewModifier {
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
        modifier(
            LadleFontModifier(
                size: style.baseSize,
                relativeTo: style.relativeTextStyle,
                weight: style.weight,
                width: style.width,
                design: style.design
            )
        )
    }

    func ladleScaledFont(
        size: CGFloat,
        relativeTo textStyle: Font.TextStyle,
        weight: Font.Weight = .regular,
        width: Font.Width = .standard,
        design: Font.Design = .default
    ) -> some View {
        modifier(
            LadleFontModifier(
                size: size,
                relativeTo: textStyle,
                weight: weight,
                width: width,
                design: design
            )
        )
    }
}
