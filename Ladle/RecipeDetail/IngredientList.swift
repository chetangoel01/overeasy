import LadleCore
import SwiftUI

struct IngredientList: View {
    let ingredients: [Ingredient]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LadleSectionHeader(
                title: "Ingredients",
                detail: countText(ingredients.count, "ingredient")
            )
            .padding(.bottom, 10)

            ForEach(Array(ingredients.enumerated()), id: \.element.id) {
                index,
                ingredient in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(LadleTheme.Label.accent)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)

                        Text(ingredient.cookingDetailText)
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.ink)

                        Spacer(minLength: 0)
                    }

                    if let uncertainty = ingredient.uncertainty {
                        Label(
                            uncertainty.reason,
                            systemImage: "exclamationmark.circle"
                        )
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.Label.accent)
                        .padding(.leading, 16)
                        .accessibilityLabel(
                            "Uncertain ingredient: \(uncertainty.reason)"
                        )
                    }
                }
                .padding(.vertical, 13)

                if index < ingredients.count - 1 {
                    Divider()
                        .overlay(LadleTheme.ink.opacity(0.08))
                        .padding(.leading, 16)
                }
            }
        }
    }
}
