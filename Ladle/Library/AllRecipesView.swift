import LadleCore
import SwiftUI

struct AllRecipesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var viewModel: LibraryViewModel
    let addRecipe: () -> Void
    let openRecipe: (Recipe) -> Void
    let openCollection: (LibraryRecipeCollection) -> Void
    let presentFilters: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.regular) {
                searchField
                if viewModel.recipes.isEmpty {
                    firstRecipeState
                } else {
                    recipeHeader
                    activeFilters
                    recipes
                    if showsCollections {
                        collections
                    }
                }
            }
            .padding(.horizontal, LadleTheme.Spacing.regular)
            .padding(.bottom, LadleTheme.Layout.scrollTail)
        }
        .scrollIndicators(.hidden)
        .background(LadleTheme.paper)
        .sensoryFeedback(
            .selection,
            trigger: viewModel.displayMode
        )
        .sensoryFeedback(
            .selection,
            trigger: filterChips.map(\.title)
        )
        .accessibilityIdentifier("library.all-recipes")
    }

    private var searchField: some View {
        HStack(spacing: LadleTheme.Layout.iconGap) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LadleTheme.mutedInk)
            TextField("Search recipes", text: $viewModel.searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LadleTheme.mutedInk)
                        .frame(width: 32, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .ladleFont(.body)
        .foregroundStyle(LadleTheme.ink)
        .padding(.horizontal, LadleTheme.Layout.cardPadding)
        .frame(minHeight: 48)
        .background(
            LadleTheme.oat,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
        )
        .accessibilityIdentifier("library.search")
    }

    private var firstRecipeState: some View {
        LadleStateView(
            systemImage: "book.closed",
            title: "No recipes yet",
            message: "Save a link or create a recipe to begin.",
            primaryTitle: "Add recipe",
            primaryAction: addRecipe
        )
        .padding(.top, LadleTheme.Spacing.regular)
    }

    private var recipeHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                Text(sectionTitle)
                    .ladleFont(.section)
                    .foregroundStyle(LadleTheme.ink)
                Text(recipeCountText)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.mutedInk)
            }

            Spacer()

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
                controlIcon("arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort recipes")
            .buttonStyle(LadlePressButtonStyle())

            Button(action: presentFilters) {
                controlIcon(
                    filterChips.isEmpty
                        ? "line.3.horizontal.decrease"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
            .accessibilityLabel(filterButtonTitle)
            .buttonStyle(LadlePressButtonStyle())

            Menu {
                Button {
                    setDisplayMode(.grid)
                } label: {
                    Label(
                        "Grid",
                        systemImage: viewModel.displayMode == .grid
                            ? "checkmark"
                            : "square.grid.2x2"
                    )
                }
                Button {
                    setDisplayMode(.list)
                } label: {
                    Label(
                        "List",
                        systemImage: viewModel.displayMode == .list
                            ? "checkmark"
                            : "list.bullet"
                    )
                }
                Button {
                    setDisplayMode(.gallery)
                } label: {
                    Label(
                        "Gallery",
                        systemImage: viewModel.displayMode == .gallery
                            ? "checkmark"
                            : "photo.on.rectangle.angled"
                    )
                }
            } label: {
                controlIcon(displayModeSystemImage)
            }
            .accessibilityLabel("Recipe view")
            .accessibilityValue(displayModeTitle)
            .buttonStyle(LadlePressButtonStyle())
        }
    }

    private var collections: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Layout.rowGap) {
            Text("Collections")
                .ladleFont(.section)
                .foregroundStyle(LadleTheme.ink)

            VStack(spacing: 0) {
                ForEach(viewModel.collectionRows, id: \.identifier) { row in
                    Button {
                        openCollection(row.collection)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: row.systemImage)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(LadleTheme.accentText)
                                .frame(width: Self.collectionIconWidth)
                            Text(row.title)
                                .ladleFont(.body)
                                .foregroundStyle(LadleTheme.ink)
                            Spacer()
                            Text(row.count.formatted())
                                .ladleFont(.metadata)
                                .foregroundStyle(LadleTheme.mutedInk)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(LadleTheme.mutedInk)
                        }
                        .frame(minHeight: 52)
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.plain)

                    if row.showsDivider {
                        Divider()
                            .padding(
                                .leading,
                                LadleTheme.dividerInset(
                                    iconWidth: Self.collectionIconWidth,
                                    leadingPadding: LadleTheme.Spacing.medium
                                )
                            )
                    }
                }
            }
            .background(
                LadleTheme.oat,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
        }
        .padding(.top, 8)
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
                                tint: LadleTheme.Intent.success.opacity(0.45)
                            )
                        }
                        .buttonStyle(LadlePressButtonStyle())
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
        } else if viewModel.displayMode == .list {
            LazyVStack(spacing: 12) {
                recipeRows
            }
        } else {
            LazyVGrid(
                columns: galleryColumns,
                spacing: LadleTheme.Spacing.compact
            ) {
                recipeGalleryCards
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

    private var recipeGalleryCards: some View {
        ForEach(viewModel.visibleRecipes) { recipe in
            RecipeGalleryCard(
                recipe: recipe,
                openRecipe: { openRecipe(recipe) },
                toggleFavorite: {
                    viewModel.toggleFavorite(recipeID: recipe.id)
                }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(LadleTheme.Label.accent)
            Text("No recipes found")
                .ladleFont(.section)
                .foregroundStyle(LadleTheme.ink)
            Text("Try another filter or return to all recipes.")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.mutedInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LadleTheme.Spacing.cooking)
    }

    /// Width of a collection row's leading icon. The row dividers derive
    /// their inset from this. The literal it replaces already matched the
    /// label origin, so this keeps a correct alignment correct rather than
    /// fixing a broken one.
    private static let collectionIconWidth: CGFloat = 28

    private var columns: [GridItem] {
        // No maximum. A capped column cannot fill the content width, and
        // LazyVGrid centres the shortfall, so the grid sits inside the screen
        // margin that the title, search field and collections all share.
        // At 402 points that cap left the grid 31 points in on both sides,
        // and stranded the single large-type column 112 points in.
        let column = GridItem(
            .flexible(),
            spacing: LadleTheme.Spacing.regular,
            alignment: .top
        )
        return dynamicTypeSize >= .xxxLarge
            ? [GridItem(.flexible(), alignment: .top)]
            : [column, column]
    }

    private var galleryColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible()), GridItem(.flexible())]
            : Array(
                repeating: GridItem(
                    .flexible(),
                    spacing: LadleTheme.Spacing.compact
                ),
                count: 3
            )
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

    private func controlIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(LadleTheme.ink)
            .frame(width: 44, height: 44)
    }

    private func setDisplayMode(_ mode: LibraryDisplayMode) {
        guard viewModel.displayMode != mode else { return }
        if reduceMotion {
            viewModel.displayMode = mode
        } else {
            withAnimation(
                .snappy(duration: 0.25, extraBounce: 0)
            ) {
                viewModel.displayMode = mode
            }
        }
    }

    private var displayModeSystemImage: String {
        switch viewModel.displayMode {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        case .gallery: "photo.on.rectangle.angled"
        }
    }

    private var displayModeTitle: String {
        switch viewModel.displayMode {
        case .grid: "Grid"
        case .list: "List"
        case .gallery: "Gallery"
        }
    }

    private var filterButtonTitle: String {
        filterChips.isEmpty ? "Filters" : "Filters \(filterChips.count)"
    }

    private var recipeCountText: String {
        let count = viewModel.visibleRecipes.count
        return count == 1 ? "1 recipe" : "\(count) recipes"
    }

    private var sectionTitle: String {
        if !viewModel.searchText.isEmpty {
            return "Results"
        }
        if viewModel.selectedCollection != .all {
            return viewModel.selectedCollection.title
        }
        return "Recent"
    }

    private var showsCollections: Bool {
        viewModel.searchText.isEmpty
            && viewModel.selectedCollection == .all
            && filterChips.isEmpty
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
