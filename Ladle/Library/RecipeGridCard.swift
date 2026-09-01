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
                    .font(.system(size: LadleTheme.IconSize.small, weight: .semibold))
                    .foregroundStyle(
                        recipe.isFavorite
                            ? LadleTheme.Label.accent
                            : LadleTheme.Label.primary
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
                .foregroundStyle(LadleTheme.Label.primary)
                .lineLimit(2, reservesSpace: true)

            // Two lines allowed, none reserved. The facts fit one line at
            // every non-accessibility size, so reserving the second left
            // roughly 18 points of air under every card and inflated the gap
            // between grid rows well past the 24-point step the grid is set
            // to. The title above still reserves its space: it genuinely
            // wraps, and reserving is what keeps two cards in a row sharing a
            // baseline.
            Text(recipe.libraryFacts.isEmpty ? " " : recipe.libraryFacts)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.primary.opacity(0.58))
                .lineLimit(2)
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
        // The square cell is established by a clear box and the artwork is
        // clipped into it, exactly as the grid card does. Putting
        // `.aspectRatio(1, contentMode: .fill)` on the artwork itself grew the
        // view to its own aspect ratio instead: a clipShape only clips what is
        // drawn, not the space taken, so a portrait photo overflowed its cell
        // and covered the neighbouring rows. Square fixture images hid this —
        // for them fill and fit are the same — so it only ever showed with
        // real artwork.
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
