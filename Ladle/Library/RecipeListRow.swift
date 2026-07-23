import Foundation
import LadleCore
import SwiftUI

struct RecipeListRow: View {
    let recipe: Recipe
    let toggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            recipeImage

            VStack(alignment: .leading, spacing: 6) {
                Text(recipe.source.libraryTitle.uppercased())
                    .font(LadleTypography.eyebrow)
                    .tracking(1.1)
                    .foregroundStyle(LadleTheme.paprika)

                Text(recipe.title)
                    .font(LadleTypography.recipeTitle)
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
                .font(LadleTypography.metadata)
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recipe.list.\(recipe.librarySlug)")
    }

    @ViewBuilder
    private var recipeImage: some View {
        if let imageName = recipe.images.first?.localName {
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: 96, height: 96)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                )
                .clipped()
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LadleTheme.field)
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: "fork.knife")
                        .foregroundStyle(LadleTheme.paprika)
                }
                .accessibilityHidden(true)
        }
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
