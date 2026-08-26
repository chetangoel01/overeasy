import LadleCore
import SwiftUI

enum RecipeContextAction: Hashable {
    case open
    case toggleFavorite
}

struct RecipeContextMenuPresentation: Equatable {
    let actions: [RecipeContextAction] = [.open, .toggleFavorite]
    let openTitle = "Open Recipe"
    let favoriteTitle: String
    let favoriteSystemImage: String

    init(recipe: Recipe) {
        favoriteTitle = recipe.isFavorite
            ? "Remove from Favorites"
            : "Add to Favorites"
        favoriteSystemImage = recipe.isFavorite ? "heart.slash" : "heart"
    }
}

extension View {
    func recipeContextMenu(
        recipe: Recipe,
        openRecipe: @escaping () -> Void,
        toggleFavorite: @escaping () -> Void
    ) -> some View {
        let presentation = RecipeContextMenuPresentation(recipe: recipe)
        return contextMenu {
            Button(
                presentation.openTitle,
                systemImage: "book.pages",
                action: openRecipe
            )
            Button(
                presentation.favoriteTitle,
                systemImage: presentation.favoriteSystemImage,
                action: toggleFavorite
            )
        } preview: {
            RecipeContextPreview(recipe: recipe)
        }
    }
}

private struct RecipeContextPreview: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecipeArtworkView(
                recipeID: recipe.id,
                image: recipe.images.first
            )
            .frame(height: 210)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
            )

            Text(recipe.creatorAccountLabel)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.accent)
            Text(recipe.title)
                .ladleFont(.section)
                .foregroundStyle(LadleTheme.Label.primary)
                .lineLimit(2)
            if !recipe.libraryFacts.isEmpty {
                Text(recipe.libraryFacts)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(LadleTheme.Surface.porcelain)
    }
}
