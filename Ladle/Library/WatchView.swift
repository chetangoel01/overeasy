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
                    LazyVStack(spacing: 16) {
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
                    .padding(.bottom, 36)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(LadleTheme.plum)
        .navigationTitle("Watch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(LadleTheme.plum, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .fullScreenCover(item: $cookingViewModel) {
            FullRecipeView(viewModel: $0)
        }
        .accessibilityIdentifier("library.watch.root")
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No saved videos",
            systemImage: "play.rectangle",
            description: Text(
                "Recipes imported from TikTok, Instagram, and YouTube appear here."
            )
        )
        .foregroundStyle(LadleTheme.onAccent)
    }
}

private struct WatchRecipeCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recipe: Recipe
    let openRecipe: () -> Void
    let startCooking: () -> Void
    let toggleFavorite: () -> Void

    @State private var panel: WatchPanel = .overview
    @State private var isVideoPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sourceBar
            media
            Text(recipe.title)
                .ladleFont(.section)
                .foregroundStyle(LadleTheme.ink)
                .lineLimit(2)
            panelPicker
            panelContent
            actions
        }
        .padding(16)
        .background(
            LadleTheme.paper,
            in: RoundedRectangle(
                cornerRadius: 26,
                style: .continuous
            )
        )
        .accessibilityIdentifier("watch.\(recipe.librarySlug)")
        .sensoryFeedback(.selection, trigger: recipe.isFavorite)
    }

    private var sourceBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(LadleTheme.paprika)
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.creatorAccountLabel)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.ink)
                if recipe.creatorName != nil {
                    Text(recipe.source.libraryTitle)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.mutedInk)
                }
            }
            .lineLimit(1)
            Spacer()
            ShareLink(item: recipe.originalURL) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Share \(recipe.title)")
            Button(action: toggleFavorite) {
                Image(systemName: recipe.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(
                        recipe.isFavorite
                            ? LadleTheme.paprika
                            : LadleTheme.ink
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
        .foregroundStyle(LadleTheme.ink)
    }

    private var media: some View {
        ZStack {
            WatchRecipeImage(recipe: recipe)
            Button {
                isVideoPresented = true
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(LadleTheme.plum)
                    .frame(width: 58, height: 58)
                    .background(LadleTheme.onAccent.opacity(0.94), in: Circle())
            }
            .accessibilityLabel("Play video")
            .sheet(isPresented: $isVideoPresented) {
                VideoEmbedSheet(recipe: recipe)
            }
        }
        .frame(height: 230)
        .clipShape(
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    private var panelPicker: some View {
        HStack(spacing: 4) {
            ForEach(WatchPanel.allCases) { candidate in
                Button {
                    panel = candidate
                } label: {
                    Text(candidate.rawValue)
                        .ladleFont(.metadata)
                        .foregroundStyle(
                            panel == candidate
                                ? LadleTheme.onAccent
                                : LadleTheme.ink
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            panel == candidate
                                ? LadleTheme.plum
                                : Color.clear,
                            in: Capsule()
                        )
                }
            }
        }
        .padding(4)
        .background(LadleTheme.field, in: Capsule())
    }

    @ViewBuilder
    private var panelContent: some View {
        switch panel {
        case .overview:
            VStack(alignment: .leading, spacing: 8) {
                Text(recipe.description)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.ink.opacity(0.72))
                    .lineLimit(4)
                Text(metadata)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.mutedInk)
            }
        case .ingredients:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(recipe.orderedIngredients.prefix(4)) {
                    Text("• \($0.cookingDetailText)")
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.ink)
                        .lineLimit(1)
                }
                remainingText(
                    shown: min(recipe.orderedIngredients.count, 4),
                    total: recipe.orderedIngredients.count
                )
            }
        case .method:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(recipe.orderedSteps.prefix(3)) { step in
                    Text("\(step.orderIndex + 1). \(step.instruction)")
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.ink)
                        .lineLimit(2)
                }
                remainingText(
                    shown: min(recipe.orderedSteps.count, 3),
                    total: recipe.orderedSteps.count
                )
            }
        }
    }

    private var actions: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) {
                    actionButtons
                }
            } else {
                HStack(spacing: 10) {
                    actionButtons
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if recipe.canStartCooking {
            Button("Open recipe", action: openRecipe)
                .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
            Button("Start cooking", action: startCooking)
                .buttonStyle(LadlePrimaryButtonStyle())
        } else {
            Button("Check recipe", action: openRecipe)
                .buttonStyle(LadlePrimaryButtonStyle())
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

    @ViewBuilder
    private func remainingText(shown: Int, total: Int) -> some View {
        if total > shown {
            Text("+\(total - shown) more in the full recipe")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.mutedInk)
        }
    }
}

private enum WatchPanel: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case ingredients = "Ingredients"
    case method = "Method"

    var id: Self { self }
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
