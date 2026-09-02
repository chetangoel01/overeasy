import LadleCore
import SwiftUI

struct IngredientList: View {
    @Environment(\.ladleAccent) private var accent

    let ingredients: [Ingredient]

    /// Whether each row leads with the ingredient's watercolour.
    ///
    /// Off by default because this list is also the reimport sheet's, where
    /// the reader is comparing two versions of the same text and a column of
    /// pictures down the side is noise. Recipe detail turns it on.
    var showsIcons = false

    /// The leading art is a fixed square whatever it holds — a painting, a
    /// pantry container, or the badge that stands in where the set has no
    /// art. Fixed, and shared by all three, so a row cannot change height
    /// depending on whether its ingredient happens to have a picture: the
    /// list would twitch as it scrolled, and the divider would move with it.
    private static let iconWidth: CGFloat = 40

    /// Width of the bullet leading each ingredient when the icons are off.
    private static let bulletWidth: CGFloat = 6

    /// The row divider and the uncertainty note both hang off whatever leads
    /// the row, so all three stay on one origin whichever it is.
    private var labelOrigin: CGFloat {
        LadleTheme.dividerInset(
            iconWidth: showsIcons ? Self.iconWidth : Self.bulletWidth
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LadleSectionHeader(
                title: "Ingredients",
                detail: countText(ingredients.count, "ingredient")
            )
            .padding(.bottom, LadleTheme.Layout.rowGap)

            ForEach(Array(ingredients.enumerated()), id: \.element.id) {
                index,
                ingredient in
                VStack(alignment: .leading, spacing: LadleTheme.Spacing.compact) {
                    HStack(
                        // A 40-point square cannot sit on a text baseline —
                        // its bottom edge would land there and the art would
                        // hang above the line. The bullet still can, and
                        // should, so that a wrapped row keeps its dot on the
                        // first line.
                        alignment: showsIcons ? .center : .firstTextBaseline,
                        spacing: LadleTheme.Layout.iconGap
                    ) {
                        leading(for: ingredient)
                            .accessibilityHidden(true)

                        Text(ingredient.cookingDetailText)
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.Label.primary)

                        Spacer(minLength: 0)
                    }

                    if let uncertainty = ingredient.uncertainty {
                        Label(
                            uncertainty.reason,
                            systemImage: "exclamationmark.circle"
                        )
                        .ladleFont(.metadata)
                        .foregroundStyle(accent.label)
                        .padding(.leading, labelOrigin)
                        .accessibilityLabel(
                            "Uncertain ingredient: \(uncertainty.reason)"
                        )
                    }
                }
                .padding(.vertical, LadleTheme.Spacing.medium)

                if index < ingredients.count - 1 {
                    Divider()
                        .overlay(LadleTheme.Label.primary.opacity(0.08))
                        .padding(.leading, labelOrigin)
                }
            }
        }
    }

    @ViewBuilder
    private func leading(for ingredient: Ingredient) -> some View {
        if showsIcons {
            if let slug = IngredientIconResolver.slug(for: ingredient.name) {
                // Bare in both appearances. The set's README warns against
                // pure black, so the paintings were composited onto
                // `porcelain` at both #F2F4F6 and #101214 before this was
                // written — see the dark-ground check in the companion doc.
                // Nothing vanishes: the leaves are bright mid-greens and even
                // the aubergine keeps its highlights. A badge disc behind
                // every painting was the alternative, and it read heavier
                // than the list wants and clipped the art that reaches past
                // a 40-point circle.
                Image(slug)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.iconWidth, height: Self.iconWidth)
            } else {
                Circle()
                    .fill(LadleTheme.Surface.badge)
                    .frame(width: Self.iconWidth, height: Self.iconWidth)
                    .overlay {
                        // Says "an ingredient", says nothing about which one.
                        // Every category-shaped glyph — leaf, drop, carrot —
                        // is a claim about the row, and getting that claim
                        // wrong is the failure this whole feature is built to
                        // avoid. Paneer is not a leaf.
                        Image(systemName: "fork.knife")
                            .font(.system(size: LadleTheme.IconSize.medium))
                            .foregroundStyle(LadleTheme.Label.secondary)
                    }
            }
        } else {
            Circle()
                .fill(LadleTheme.Label.secondary)
                .frame(width: Self.bulletWidth, height: Self.bulletWidth)
        }
    }
}
