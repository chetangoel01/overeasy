import LadleCore
import SwiftUI

struct LibraryHomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let viewModel: LibraryViewModel
    let openRecipe: (Recipe) -> Void
    let openCollection: (LibraryRecipeCollection) -> Void
    let openImportInbox: () -> Void
    let openWatch: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.generous) {
                importInbox
                watch
                savedThisWeek
                collections
            }
            .padding(.horizontal, LadleTheme.Spacing.regular)
            .padding(.bottom, 44)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("library.home")
    }

    private var importInbox: some View {
        Button(action: openImportInbox) {
            HStack(spacing: 14) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(LadleTheme.paprika)
                    .frame(width: 44, height: 44)
                    .background(LadleTheme.review, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import inbox")
                        .ladleFont(.bodyStrong)
                        .foregroundStyle(LadleTheme.ink)
                    Text(importInboxDetail)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.mutedInk)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(LadleTheme.mutedInk)
            }
            .padding(14)
            .ladleCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.import-inbox")
    }

    private var importInboxDetail: String {
        let count = viewModel.importAttentionCount
        return count == 0
            ? "Imports and recovery"
            : "\(count) need\(count == 1 ? "s" : "") attention"
    }

    private var watch: some View {
        Button(action: openWatch) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Watch")
                            .ladleFont(.section)
                            .foregroundStyle(LadleTheme.paper)
                        Text("Return to saved recipe videos")
                            .ladleFont(.metadata)
                            .foregroundStyle(LadleTheme.paper.opacity(0.68))
                    }
                    Spacer()
                    Image(systemName: "play.fill")
                        .foregroundStyle(LadleTheme.plum)
                        .frame(width: 44, height: 44)
                        .background(LadleTheme.paper, in: Circle())
                }
                HStack(spacing: 8) {
                    ForEach(
                        viewModel.watchRecipes.prefix(columnCount)
                    ) { recipe in
                        watchThumbnail(recipe)
                    }
                }
            }
            .padding(16)
            .background(
                LadleTheme.plum,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.watch")
    }

    @ViewBuilder
    private func watchThumbnail(_ recipe: Recipe) -> some View {
        if recipe.images.first != nil {
            RecipeArtworkView(
                recipeID: recipe.id,
                image: recipe.images.first
            )
            .frame(height: 78)
            .frame(maxWidth: .infinity)
            .clipShape(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .clipped()
            .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LadleTheme.paper.opacity(0.12))
                .frame(height: 78)
                .overlay {
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(LadleTheme.paper)
                }
                .accessibilityHidden(true)
        }
    }

    private var savedThisWeek: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(
                title: "Saved this week",
                detail: countText(viewModel.savedThisWeek.count)
            )

            if viewModel.savedThisWeek.isEmpty {
                Text("New saves will collect here for quick return.")
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.mutedInk)
                    .padding(.vertical, 18)
            } else {
                LazyVGrid(
                    columns: savedColumns,
                    spacing: 12
                ) {
                    ForEach(
                        viewModel.savedThisWeek.prefix(3)
                    ) { recipe in
                        HomeRecipeThumbnail(
                            recipe: recipe,
                            action: { openRecipe(recipe) }
                        )
                    }
                }
            }
        }
    }

    private var collections: some View {
        VStack(alignment: .leading, spacing: 0) {
            LadleSectionHeader(
                title: "Come back to",
                detail: "Useful groups"
            )
            .padding(.bottom, 6)

            collectionRow(
                "Ready in 30 minutes",
                count: viewModel.quickRecipes.count,
                collection: .quick
            )
            collectionRow(
                "Favorited",
                count: viewModel.favoriteRecipes.count,
                collection: .favorites
            )
            collectionRow(
                "Haven’t cooked yet",
                count: viewModel.uncookedRecipes.count,
                collection: .uncooked
            )
        }
    }

    private func collectionRow(
        _ title: String,
        count: Int,
        collection: LibraryRecipeCollection
    ) -> some View {
        Button {
            openCollection(collection)
        } label: {
            HStack {
                Text(title)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                Spacer()
                Text("\(count)")
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.mutedInk)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LadleTheme.mutedInk)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Divider().overlay(LadleTheme.ink.opacity(0.08))
        }
    }

    private func countText(_ count: Int) -> String {
        count == 1 ? "1 recipe" : "\(count) recipes"
    }

    private var savedColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: columnCount
        )
    }

    private var columnCount: Int {
        dynamicTypeSize.isAccessibilitySize ? 1 : 3
    }
}

private struct HomeRecipeThumbnail: View {
    let recipe: Recipe
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                recipeImage
                Text(recipe.title)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(recipe.title)")
    }

    @ViewBuilder
    private var recipeImage: some View {
        if recipe.images.first != nil {
            RecipeArtworkView(
                recipeID: recipe.id,
                image: recipe.images.first
            )
            .aspectRatio(1, contentMode: .fit)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
            .clipped()
            .accessibilityHidden(true)
        } else {
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
            .fill(LadleTheme.field)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Image(systemName: "frying.pan")
                    .foregroundStyle(LadleTheme.paprika)
            }
            .accessibilityHidden(true)
        }
    }
}
