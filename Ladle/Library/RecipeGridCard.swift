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

            // Neither of these reserves space for a line it may not use. The
            // reserve was there to keep the facts of two cards in a row on
            // one baseline, but it charges every card the full two lines
            // whether or not it needs them: a row of short titles carried a
            // 25-point void between the title and its calories, while a row
            // of wrapping titles sat correctly. The rhythm changed row to row
            // for no reason a reader could see. The cost of dropping it is
            // that a row pairing a one-line title with a two-line one no
            // longer aligns its facts — which is a far quieter defect than
            // the hole it replaces.
            Text(recipe.title)
                .ladleFont(.recipeTitle)
                .foregroundStyle(LadleTheme.Label.primary)
                .lineLimit(2)

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
