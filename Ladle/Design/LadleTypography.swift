import SwiftUI

enum LadleTextStyle {
    case display
    case title
    case recipeTitle
    case section
    case body
    case bodyStrong
    case metadata
    case eyebrow

    var baseSize: CGFloat {
        switch self {
        case .display:
            42
        case .title:
            31
        case .recipeTitle:
            21
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
            .black
        case .recipeTitle, .section:
            .heavy
        case .bodyStrong:
            .semibold
        case .body:
            .regular
        case .metadata:
            .medium
        case .eyebrow:
            .semibold
        }
    }

    var width: Font.Width {
        switch self {
        case .display, .title:
            .expanded
        case .eyebrow:
            .condensed
        case .recipeTitle, .section, .body, .bodyStrong, .metadata:
            .standard
        }
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
