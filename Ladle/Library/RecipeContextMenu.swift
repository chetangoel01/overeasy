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
        return ladleContextMenu {
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

    /// A context menu whose preview can see the app's environment.
    ///
    /// UIKit hosts the preview in a hierarchy of its own, and custom SwiftUI
    /// environment values do not follow it there: `remoteImageCache` arrived
    /// as `nil` and `ladleAccent` as its default, so every preview drew a
    /// placeholder pan in tomato whatever the row beneath it showed. The two
    /// values are read where the menu is attached and handed over
    /// explicitly. Every recipe preview goes through here so the next one
    /// cannot forget to.
    func ladleContextMenu<MenuItems: View, Preview: View>(
        @ViewBuilder menuItems: @escaping () -> MenuItems,
        @ViewBuilder preview: @escaping () -> Preview
    ) -> some View {
        modifier(
            PreviewEnvironmentContextMenu(
                menuItems: menuItems,
                preview: preview
            )
        )
    }
}

private struct PreviewEnvironmentContextMenu<
    MenuItems: View,
    Preview: View
>: ViewModifier {
    @Environment(\.remoteImageCache) private var imageCache
    @Environment(\.ladleAccent) private var accent

    let menuItems: () -> MenuItems
    let preview: () -> Preview

    func body(content: Content) -> some View {
        content.contextMenu(menuItems: menuItems) {
            preview()
                .environment(\.remoteImageCache, imageCache)
                .environment(\.ladleAccent, accent)
        }
    }
}

private struct RecipeContextPreview: View {
    @Environment(\.ladleAccent) private var accent

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
                .foregroundStyle(accent.label)
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
