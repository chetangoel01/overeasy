import LadleCore
import SwiftUI

struct WatchView: View {
    @Bindable var viewModel: LibraryViewModel
    let openRecipe: (Recipe) -> Void

    @State private var cookingViewModel: CookingViewModel?

    var body: some View {
        Group {
            if viewModel.watchRecipes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: LadleTheme.Spacing.generous) {
                        ForEach(viewModel.watchRecipes) { recipe in
                            WatchRecipeCard(
                                recipe: recipe,
                                openRecipe: { openRecipe(recipe) },
                                startCooking: {
                                    cookingViewModel = CookingViewModel(
                                        recipe: recipe
                                    )
                                },
                                toggleFavorite: {
                                    viewModel.toggleFavorite(
                                        recipeID: recipe.id
                                    )
                                }
                            )
                        }
                    }
                    .padding(.horizontal, LadleTheme.Spacing.regular)
                    .padding(.bottom, 44)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(LadleTheme.paper)
        .fullScreenCover(item: $cookingViewModel) {
            FullRecipeView(viewModel: $0)
        }
        .accessibilityIdentifier("library.watch.root")
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No saved videos",
            systemImage: "play.rectangle",
            description: Text("Saved video recipes appear here.")
        )
        .foregroundStyle(LadleTheme.ink)
    }
}

private struct WatchRecipeCard: View {
    let recipe: Recipe
    let openRecipe: () -> Void
    let startCooking: () -> Void
    let toggleFavorite: () -> Void

    @State private var isVideoPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            media
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recipe.title)
                        .ladleFont(.section)
                        .foregroundStyle(LadleTheme.ink)
                        .lineLimit(2)
                    Text(metadata)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.mutedInk)
                }
                Spacer()
                favoriteButton
            }
            actions
        }
        .accessibilityIdentifier("watch.\(recipe.librarySlug)")
        .sensoryFeedback(.selection, trigger: recipe.isFavorite)
    }

    private var favoriteButton: some View {
        Button(action: toggleFavorite) {
            Image(systemName: recipe.isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(
                    recipe.isFavorite
                        ? LadleTheme.paprika
                        : LadleTheme.mutedInk
                )
                .frame(width: 44, height: 44)
        }
        .buttonStyle(LadlePressButtonStyle())
        .accessibilityLabel(
            recipe.isFavorite
                ? "Remove from favorites"
                : "Add to favorites"
        )
    }

    private var media: some View {
        ZStack {
            WatchRecipeImage(recipe: recipe)
                .overlay(alignment: .topLeading) {
                    Text(recipe.creatorName ?? recipe.source.libraryTitle)
                        .ladleFont(.metadata)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 30)
                        .background(.black.opacity(0.48), in: Capsule())
                        .padding(12)
                }
            Button {
                isVideoPresented = true
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(LadleTheme.fixedInk)
                    .frame(width: 58, height: 58)
                    .background(LadleTheme.onAccent.opacity(0.94), in: Circle())
            }
            .accessibilityLabel("Play video")
            .sheet(isPresented: $isVideoPresented) {
                VideoEmbedSheet(recipe: recipe)
            }
        }
        .frame(height: 300)
        .clipShape(
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if recipe.canStartCooking {
                Button("Open", action: openRecipe)
                    .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
                Button("Start cooking", action: startCooking)
                    .buttonStyle(LadlePrimaryButtonStyle())
            } else {
                Button("Review recipe", action: openRecipe)
                    .buttonStyle(LadlePrimaryButtonStyle())
            }
        }
    }

    private var metadata: String {
        [
            recipe.totalMinutes.map { "\($0) min" },
            recipe.libraryNutrition?.proteinGrams.map {
                "\(NSDecimalNumber(decimal: $0).stringValue) g protein"
            },
            recipe.ladleYieldText,
        ]
        .compactMap(\.self)
        .joined(separator: " · ")
    }

}

private struct WatchRecipeImage: View {
    let recipe: Recipe

    @ViewBuilder
    var body: some View {
        if recipe.images.first != nil {
            RecipeArtworkView(
                recipeID: recipe.id,
                image: recipe.images.first
            )
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(LadleTheme.field)
            .overlay {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 30))
                    .foregroundStyle(LadleTheme.paprika)
            }
    }
}
