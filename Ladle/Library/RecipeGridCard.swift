import LadleCore
import SwiftUI

struct RecipeGridCard: View {
    let recipe: Recipe
    let openRecipe: () -> Void
    let toggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
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
                            ? LadleTheme.Label.accent
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
                .lineLimit(2, reservesSpace: true)

            Text(recipe.libraryFacts.isEmpty ? " " : recipe.libraryFacts)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.58))
                .lineLimit(2, reservesSpace: true)
                .accessibilityHidden(recipe.libraryFacts.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .accessibilityIdentifier("recipe.grid.\(recipe.librarySlug)")
        .sensoryFeedback(.selection, trigger: recipe.isFavorite)
    }

    @ViewBuilder
    private var recipeImage: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RecipeArtworkView(
                    recipeID: recipe.id,
                    image: recipe.images.first
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
            )
            .accessibilityHidden(true)
    }

    private var favoriteAccessibilityLabel: String {
        recipe.isFavorite
            ? "Remove \(recipe.title) from favorites"
            : "Add \(recipe.title) to favorites"
    }
}

struct RecipeGalleryCard: View {
    let recipe: Recipe
    let openRecipe: () -> Void
    let toggleFavorite: () -> Void

    var body: some View {
        RecipeArtworkView(
            recipeID: recipe.id,
            image: recipe.images.first
        )
        .aspectRatio(1, contentMode: .fill)
        .clipShape(
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: openRecipe)
        .recipeContextMenu(
            recipe: recipe,
            openRecipe: openRecipe,
            toggleFavorite: toggleFavorite
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recipe.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open recipe", openRecipe)
        .accessibilityIdentifier("recipe.gallery.\(recipe.librarySlug)")
    }
}
