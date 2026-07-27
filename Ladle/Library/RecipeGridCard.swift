import LadleCore
import SwiftUI

struct RecipeGridCard: View {
    let recipe: Recipe
    let openRecipe: () -> Void
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
                .buttonStyle(LadlePressButtonStyle())
                .accessibilityLabel(favoriteAccessibilityLabel)
            }

            Text(recipe.title)
                .ladleFont(.recipeTitle)
                .foregroundStyle(LadleTheme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !recipe.libraryFacts.isEmpty {
                Text(recipe.libraryFacts)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.ink.opacity(0.58))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openRecipe)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open recipe", openRecipe)
        .accessibilityIdentifier("recipe.grid.\(recipe.librarySlug)")
        .sensoryFeedback(.selection, trigger: recipe.isFavorite)
    }

    @ViewBuilder
    private var recipeImage: some View {
        RecipeArtworkView(
            recipeID: recipe.id,
            image: recipe.images.first
        )
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
    }

    private var favoriteAccessibilityLabel: String {
        recipe.isFavorite
            ? "Remove \(recipe.title) from favorites"
            : "Add \(recipe.title) to favorites"
    }
}
