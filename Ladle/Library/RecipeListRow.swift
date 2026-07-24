import Foundation
import LadleCore
import SwiftUI

struct RecipeListRow: View {
    let recipe: Recipe
    let openRecipe: () -> Void
    let toggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            recipeImage

            VStack(alignment: .leading, spacing: 6) {
                Text(recipe.source.libraryTitle.uppercased())
                    .ladleFont(.eyebrow)
                    .tracking(1.1)
                    .foregroundStyle(LadleTheme.paprika)

                Text(recipe.title)
                    .ladleFont(.recipeTitle)
                    .foregroundStyle(LadleTheme.ink)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let totalMinutes = recipe.totalMinutes {
                        Text("\(totalMinutes) min")
                    }
                    if recipe.totalMinutes != nil, recipe.nutrition != nil {
                        Text("·")
                            .accessibilityHidden(true)
                    }
                    if let calories = recipe.nutrition?.calories {
                        Text(
                            "≈ \(NSDecimalNumber(decimal: calories).stringValue) cal"
                        )
                    }
                }
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.58))
            }

            Spacer(minLength: 4)

            Button(action: toggleFavorite) {
                Image(
                    systemName: recipe.isFavorite
                        ? "heart.fill"
                        : "heart"
                )
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(
                    recipe.isFavorite
                        ? LadleTheme.paprika
                        : LadleTheme.ink.opacity(0.52)
                )
                .frame(width: 44, height: 44)
            }
            .accessibilityLabel(
                recipe.isFavorite
                    ? "Remove \(recipe.title) from favorites"
                    : "Add \(recipe.title) to favorites"
            )
        }
        .padding(10)
        .ladleCard()
        .contentShape(Rectangle())
        .onTapGesture(perform: openRecipe)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open recipe", openRecipe)
        .accessibilityIdentifier("recipe.list.\(recipe.librarySlug)")
    }

    @ViewBuilder
    private var recipeImage: some View {
        RecipeArtworkView(
            recipeID: recipe.id,
            image: recipe.images.first
        )
        .frame(width: 96, height: 96)
        .clipShape(
            RoundedRectangle(
                cornerRadius: 12,
                style: .continuous
            )
        )
        .clipped()
        .accessibilityHidden(true)
    }
}

extension RecipeSource {
    var libraryTitle: String {
        switch self {
        case .tiktok:
            "TikTok"
        case .instagram:
            "Instagram"
        case .youtube:
            "YouTube"
        case .other:
            "Saved recipe"
        }
    }
}
