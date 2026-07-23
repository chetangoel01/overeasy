import Foundation
import LadleCore
import SwiftUI

struct RecipeGridCard: View {
    let recipe: Recipe
    let toggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                recipeImage

                Button(action: toggleFavorite) {
                    Image(
                        systemName: recipe.isFavorite
                            ? "heart.fill"
                            : "heart"
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        recipe.isFavorite
                            ? LadleTheme.paprika
                            : LadleTheme.ink
                    )
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(8)
                }
                .accessibilityLabel(favoriteAccessibilityLabel)
            }

            Text(recipe.title)
                .font(LadleTypography.recipeTitle)
                .foregroundStyle(LadleTheme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                if let totalMinutes = recipe.totalMinutes {
                    Label("\(totalMinutes) min", systemImage: "clock")
                }
                if recipe.totalMinutes != nil, recipe.nutrition != nil {
                    Text("·")
                        .accessibilityHidden(true)
                }
                if let calories = recipe.nutrition?.calories {
                    Text("≈ \(calorieText(calories)) cal")
                }
            }
            .font(LadleTypography.metadata)
            .foregroundStyle(LadleTheme.ink.opacity(0.58))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recipe.grid.\(recipe.librarySlug)")
    }

    @ViewBuilder
    private var recipeImage: some View {
        if let imageName = recipe.images.first?.localName {
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(height: 146)
                .frame(maxWidth: .infinity)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.card,
                        style: .continuous
                    )
                )
                .clipped()
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
            .fill(LadleTheme.field)
            .frame(height: 146)
            .overlay {
                Image(systemName: "fork.knife")
                    .foregroundStyle(LadleTheme.paprika)
            }
            .accessibilityHidden(true)
        }
    }

    private var favoriteAccessibilityLabel: String {
        recipe.isFavorite
            ? "Remove \(recipe.title) from favorites"
            : "Add \(recipe.title) to favorites"
    }

    private func calorieText(_ calories: Decimal) -> String {
        NSDecimalNumber(decimal: calories).stringValue
    }
}

extension Recipe {
    var librarySlug: String {
        title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
