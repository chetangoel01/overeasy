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
                    .foregroundStyle(LadleTheme.Label.secondary)

                Text(recipe.title)
                    .ladleFont(.recipeTitle)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .lineLimit(1)

                if !recipe.libraryFacts.isEmpty {
                    Text(recipe.libraryFacts)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.Label.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            LadleIconButton(
                systemImage: recipe.isFavorite ? "heart.fill" : "heart",
                accessibilityLabel: recipe.isFavorite
                    ? "Remove \(recipe.title) from favorites"
                    : "Add \(recipe.title) to favorites",
                tone: .plain,
                isSelected: recipe.isFavorite,
                action: toggleFavorite
            )
        }
        // The trailing element is a 44-point hit frame around a shared
        // glyph, so it carries its own slack. Padding the trailing edge as
        // well put the heart 22 points off the card while the thumbnail sat 8
        // points off the other side. The frame supplies the trailing inset;
        // the other three edges are padded to match it, which brings the two
        // sides within two points of each other. Titles still truncate — that
        // is the hit frame's width, not this padding.
        .padding(.leading, LadleTheme.Layout.rowGap)
        .padding(.vertical, LadleTheme.Layout.rowGap)
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
        .recipeZoomSource(RecipeZoomID(recipe.id), cornerRadius: 12)
        .accessibilityHidden(true)
    }
}
