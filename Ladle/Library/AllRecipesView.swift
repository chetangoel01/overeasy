import LadleCore
import SwiftUI

struct AllRecipesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var viewModel: LibraryViewModel
    let addRecipe: () -> Void
    let openRecipe: (Recipe) -> Void
    let presentFilters: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.regular) {
                if viewModel.recipes.isEmpty {
                    firstRecipeState
                } else {
                    controls
                    activeFilters
                    LadleSectionHeader(
                        title: "All recipes",
                        detail: recipeCountText
                    )
                    recipes
                }
            }
            .padding(.horizontal, LadleTheme.Spacing.regular)
            .padding(.bottom, 44)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("library.all-recipes")
    }

    private var firstRecipeState: some View {
        LadleStateView(
            systemImage: "books.vertical",
            title: "No recipes yet",
            message:
                "Add a recipe from a link or create one yourself. Your full collection will live here.",
            primaryTitle: "Add your first recipe",
            primaryAction: addRecipe
        )
        .padding(.top, LadleTheme.Spacing.regular)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(RecipeSort.allCases, id: \.self) { sort in
                    Button {
                        viewModel.sort = sort
                    } label: {
                        if viewModel.sort == sort {
                            Label(sort.libraryTitle, systemImage: "checkmark")
                        } else {
                            Text(sort.libraryTitle)
                        }
                    }
                }
            } label: {
                controlLabel(
                    viewModel.sort.libraryTitle,
                    systemImage: "arrow.up.arrow.down"
                )
            }
            .accessibilityLabel("Sort recipes")

            Button(action: presentFilters) {
                controlLabel(
                    filterButtonTitle,
                    systemImage: "line.3.horizontal.decrease"
                )
            }
            .accessibilityLabel("Filter recipes")

            Spacer()

            Button(action: toggleDisplayMode) {
                Image(
                    systemName: viewModel.displayMode == .grid
                        ? "list.bullet"
                        : "square.grid.2x2"
                )
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LadleTheme.ink)
                .frame(width: 44, height: 44)
                .background(LadleTheme.field, in: Circle())
            }
            .accessibilityLabel(
                viewModel.displayMode == .grid
                    ? "Show recipes as a list"
                    : "Show recipes as a grid"
            )
        }
    }

    @ViewBuilder
    private var activeFilters: some View {
        if !filterChips.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(filterChips) { chip in
                        Button(action: chip.remove) {
                            LadlePill(
                                text: chip.title,
                                systemImage: "xmark",
                                tint: LadleTheme.success.opacity(0.45)
                            )
                        }
                        .accessibilityLabel("Remove filter: \(chip.title)")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var recipes: some View {
        if viewModel.visibleRecipes.isEmpty {
            emptyState
        } else if viewModel.displayMode == .grid {
            LazyVGrid(columns: columns, spacing: LadleTheme.Spacing.generous) {
                recipeCards
            }
        } else {
            LazyVStack(spacing: 12) {
                recipeRows
            }
        }
    }

    private var recipeCards: some View {
        ForEach(viewModel.visibleRecipes) { recipe in
            RecipeGridCard(
                recipe: recipe,
                openRecipe: { openRecipe(recipe) },
                toggleFavorite: {
                    viewModel.toggleFavorite(recipeID: recipe.id)
                }
            )
        }
    }

    private var recipeRows: some View {
        ForEach(viewModel.visibleRecipes) { recipe in
            RecipeListRow(
                recipe: recipe,
                openRecipe: { openRecipe(recipe) },
                toggleFavorite: {
                    viewModel.toggleFavorite(recipeID: recipe.id)
                }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(LadleTheme.paprika)
            Text("No recipes found")
                .ladleFont(.section)
                .foregroundStyle(LadleTheme.ink)
            Text("Try another filter or return to all recipes.")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.mutedInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [
                GridItem(.flexible(), spacing: LadleTheme.Spacing.regular),
                GridItem(.flexible(), spacing: LadleTheme.Spacing.regular),
            ]
    }

    private var filterChips: [LibraryFilterChip] {
        var chips: [LibraryFilterChip] = []
        if viewModel.selectedCollection != .all {
            chips.append(
                LibraryFilterChip(
                    title: viewModel.selectedCollection.title,
                    remove: { viewModel.selectedCollection = .all }
                )
            )
        }
        if viewModel.favoritesOnly {
            chips.append(
                LibraryFilterChip(
                    title: "Favorites",
                    remove: viewModel.removeFavoritesFilter
                )
            )
        }
        appendNumericFilters(to: &chips)
        return chips
    }

    private func appendNumericFilters(to chips: inout [LibraryFilterChip]) {
        if let value = viewModel.maximumTotalMinutes {
            chips.append(.init(
                title: "Up to \(value) min",
                remove: viewModel.removeMaximumTimeFilter
            ))
        }
        if let value = viewModel.maximumCalories {
            chips.append(.init(
                title: "Up to \(value.formatted()) cal",
                remove: viewModel.removeMaximumCaloriesFilter
            ))
        }
        if let value = viewModel.minimumProtein {
            chips.append(.init(
                title: "\(value.formatted()) g+ protein",
                remove: viewModel.removeMinimumProteinFilter
            ))
        }
        if let value = viewModel.maximumCarbohydrates {
            chips.append(.init(
                title: "Under \(value.formatted()) g carbs",
                remove: viewModel.removeMaximumCarbohydratesFilter
            ))
        }
        if let value = viewModel.maximumFat {
            chips.append(.init(
                title: "Under \(value.formatted()) g fat",
                remove: viewModel.removeMaximumFatFilter
            ))
        }
    }

    private func controlLabel(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(
                LadleTheme.field,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
    }

    private func toggleDisplayMode() {
        let mode: LibraryDisplayMode =
            viewModel.displayMode == .grid ? .list : .grid
        if reduceMotion {
            viewModel.displayMode = mode
        } else {
            withAnimation(.snappy(duration: 0.25)) {
                viewModel.displayMode = mode
            }
        }
    }

    private var filterButtonTitle: String {
        filterChips.isEmpty ? "Filters" : "Filters \(filterChips.count)"
    }

    private var recipeCountText: String {
        let count = viewModel.visibleRecipes.count
        return count == 1 ? "1 recipe" : "\(count) recipes"
    }
}

private struct LibraryFilterChip: Identifiable {
    let title: String
    let remove: () -> Void

    var id: String { title }
}

extension LibraryRecipeCollection {
    var title: String {
        switch self {
        case .all: "All recipes"
        case .quick: "Ready in 30 minutes"
        case .favorites: "Favorited"
        case .uncooked: "Haven’t cooked yet"
        }
    }
}

extension RecipeSort {
    var libraryTitle: String {
        switch self {
        case .recentlyAdded: "Recently saved"
        case .cookingTime: "Fastest first"
        case .highestProtein: "Highest protein"
        case .calories: "Lowest calories"
        case .alphabetical: "Recipe name"
        }
    }
}
