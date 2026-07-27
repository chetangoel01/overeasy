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
                Text(recipe.source.libraryTitle)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.ink.opacity(0.5))

                Text(recipe.title)
                    .ladleFont(.recipeTitle)
                    .foregroundStyle(LadleTheme.ink)
                    .lineLimit(2)

                if !recipe.libraryFacts.isEmpty {
                    Text(recipe.libraryFacts)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.ink.opacity(0.58))
                }
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
            .buttonStyle(LadlePressButtonStyle())
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
