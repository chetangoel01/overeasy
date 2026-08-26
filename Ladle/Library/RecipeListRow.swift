import LadleCore
import SwiftUI

struct RecipeListRow: View {
    let recipe: Recipe
    let openRecipe: () -> Void
    let toggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: LadleTheme.Spacing.medium) {
            recipeImage

            VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                Text(recipe.source.libraryTitle)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.primary.opacity(0.5))

                Text(recipe.title)
                    .ladleFont(.recipeTitle)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .lineLimit(1)

                if !recipe.libraryFacts.isEmpty {
                    Text(recipe.libraryFacts)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.Label.primary.opacity(0.58))
                        .lineLimit(1)
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
                        ? LadleTheme.Label.accent
                        : LadleTheme.Label.primary.opacity(0.52)
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
        .padding(8)
        .ladleCard()
        .contentShape(Rectangle())
        .onTapGesture(perform: openRecipe)
        .recipeContextMenu(
            recipe: recipe,
            openRecipe: openRecipe,
            toggleFavorite: toggleFavorite
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open recipe", openRecipe)
        .accessibilityIdentifier("recipe.list.\(recipe.librarySlug)")
        .sensoryFeedback(.selection, trigger: recipe.isFavorite)
    }

    @ViewBuilder
    private var recipeImage: some View {
        RecipeArtworkView(
            recipeID: recipe.id,
            image: recipe.images.first
        )
        .frame(width: 72, height: 72)
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
