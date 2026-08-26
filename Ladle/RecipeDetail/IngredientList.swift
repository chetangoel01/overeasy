import LadleCore
import SwiftUI

struct IngredientList: View {
    let ingredients: [Ingredient]

    /// Width of the bullet leading each ingredient. The row divider and the
    /// uncertainty note both derive their inset from this, so all three stay
    /// on one origin when the gap beside the bullet changes.
    private static let bulletWidth: CGFloat = 6

    private static var labelOrigin: CGFloat {
        LadleTheme.dividerInset(iconWidth: bulletWidth)
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
                    HStack(alignment: .firstTextBaseline, spacing: LadleTheme.Layout.iconGap) {
                        Circle()
                            .fill(LadleTheme.Label.accent)
                            .frame(width: Self.bulletWidth, height: Self.bulletWidth)
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
                        .foregroundStyle(LadleTheme.Label.accent)
                        .padding(.leading, Self.labelOrigin)
                        .accessibilityLabel(
                            "Uncertain ingredient: \(uncertainty.reason)"
                        )
                    }
                }
                .padding(.vertical, LadleTheme.Spacing.medium)

                if index < ingredients.count - 1 {
                    Divider()
                        .overlay(LadleTheme.Label.primary.opacity(0.08))
                        .padding(.leading, Self.labelOrigin)
                }
            }
        }
    }
}
