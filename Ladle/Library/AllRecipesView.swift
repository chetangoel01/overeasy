import LadleCore
import SwiftUI

struct AllRecipesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.ladleAccent) private var accent

    @Bindable var viewModel: LibraryViewModel
    let addRecipe: () -> Void
    let openRecipe: (Recipe) -> Void
    let openCollection: (LibraryRecipeCollection) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.regular) {
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
        .background(LadleTheme.Surface.porcelain)
        // The system search field, not a hand-rolled one in the scroll
        // content: it docks under the large title, collapses on scroll the
        // way every other iOS app does, and stays out of the push transition
        // instead of sliding across it as a pale slab.
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search recipes"
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
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
                    .foregroundStyle(LadleTheme.Label.primary)
                Text(recipeCountText)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.secondary)
            }

            Spacer()

            Menu {
                Picker(
                    "Sort recipes",
                    selection: $viewModel.sort
                ) {
                    ForEach(RecipeSort.allCases, id: \.self) { sort in
                        Label(
                            sort.libraryTitle,
                            systemImage: sort.librarySystemImage
                        )
                        .tag(sort)
                    }
                }
            } label: {
                controlIcon("arrow.up.arrow.down")
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Sort recipes")
            .buttonStyle(LadlePressButtonStyle())

            filterMenu

            Menu {
                // A binding rather than `$viewModel.displayMode`, so the
                // picker still routes through `setDisplayMode` and the grid
                // keeps its Reduce Motion-aware transition. The setter is
                // wrapped in a closure on purpose: passing the method
                // reference bare crashes swift-frontend 6.3.3 in IRGen while
                // it emits the reabstraction thunk.
                Picker(
                    "Recipe view",
                    selection: Binding(
                        get: { viewModel.displayMode },
                        set: { setDisplayMode($0) }
                    )
                ) {
                    ForEach(LibraryDisplayMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
            } label: {
                controlIcon(displayModeSystemImage)
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Recipe view")
            .accessibilityValue(displayModeTitle)
            .buttonStyle(LadlePressButtonStyle())
        }
        .padding(.trailing, -Self.controlOpticalInset)
    }

    /// How far the control group hangs past the content margin.
    ///
    /// `controlIcon` centres a small glyph in a 44-point hit frame, so the
    /// last glyph's trailing edge landed about 14 points inside the margin
    /// that the search field, the grid, the collections card and the section
    /// title all end at — the header read as misaligned by exactly half the
    /// hit frame. Pulling the group out by that slack aligns the glyphs
    /// optically while the targets keep their full 44 points and overhang the
    /// margin, which is what the system's own toolbars do.
    ///
    /// The picker rebuild does not retire it: that changed what the menus
    /// contain, while this corrects the hit frames of the *labels* beneath
    /// them, which are untouched. It would only go away if the three controls
    /// moved into the navigation bar as `ToolbarItem`s, which is a different
    /// header from the one DESIGN.md specifies.
    private static let controlOpticalInset: CGFloat =
        (LadleTheme.Control.hitTarget - LadleTheme.IconSize.small) / 2

    /// Filters is a menu of inline pickers and toggles, built like Sort
    /// beside it. Each row writes its state directly, so a tap applies at
    /// once: there is no staged copy of the filters and no Apply to forget
    /// to press. Every submenu label carries its own current value, so the
    /// whole filter state reads without opening anything.
    ///
    /// The shared tag families come first and the library's own dimensions
    /// after them, because the tags are the filter the other two tabs also
    /// answer — this menu is that one control with the library's extra rows
    /// spliced in, not a control of its own.
    private var filterMenu: some View {
        RecipeFilterMenu(
            filters: viewModel.filters,
            extraSections: {
                Divider()
                Toggle("Favorites", isOn: $viewModel.favoritesOnly)
                filterSubmenu(.time, selection: $viewModel.maximumTotalMinutes)
                filterSubmenu(
                    .calories,
                    selection: wholeNumber($viewModel.maximumCalories)
                )
                filterSubmenu(
                    .protein,
                    selection: wholeNumber($viewModel.minimumProtein)
                )
                filterSubmenu(
                    .carbohydrates,
                    selection: wholeNumber($viewModel.maximumCarbohydrates)
                )
                filterSubmenu(
                    .fat,
                    selection: wholeNumber($viewModel.maximumFat)
                )
            },
            hasActiveFilters: viewModel.hasActiveFilters,
            clearFilters: viewModel.resetFilters,
            label: {
                controlIcon(
                    filterChips.isEmpty
                        ? "line.3.horizontal.decrease"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
        )
        .accessibilityLabel(filterButtonTitle)
        .buttonStyle(LadlePressButtonStyle())
    }

    /// One submenu per dimension. Its options and their wording come from
    /// `LibraryFilter`, which words the pills too — a row by `optionTitle`,
    /// a pill by `pillTitle` — so neither can name a value the other does not.
    private func filterSubmenu(
        _ filter: LibraryFilter,
        selection: Binding<Int?>
    ) -> some View {
        Menu {
            Picker(filter.title, selection: selection) {
                Text(LibraryFilter.anyTitle).tag(Int?.none)
                ForEach(filter.options, id: \.self) { option in
                    Text(filter.optionTitle(option)).tag(Int?.some(option))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(filter.menuTitle(for: selection.wrappedValue))
        }
    }

    /// The four nutrition filters hold `Decimal` and the time filter holds
    /// `Int`, while every option any of them can take is a whole number. One
    /// bridge lets all five share the picker above rather than tagging the
    /// optional five times over.
    private func wholeNumber(_ filter: Binding<Decimal?>) -> Binding<Int?> {
        Binding(
            get: { filter.wrappedValue.map(LibraryFilter.option) },
            set: { filter.wrappedValue = $0.map { Decimal($0) } }
        )
    }

    private var collections: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Layout.rowGap) {
            Text("Collections")
                .ladleFont(.section)
                .foregroundStyle(LadleTheme.Label.primary)

            VStack(spacing: 0) {
                ForEach(viewModel.collectionRows, id: \.identifier) { row in
                    Button {
                        openCollection(row.collection)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: row.systemImage)
                                .font(.system(size: LadleTheme.IconSize.small, weight: .semibold))
                                .foregroundStyle(accent.label)
                                .frame(width: Self.collectionIconWidth)
                            Text(row.title)
                                .ladleFont(.body)
                                .foregroundStyle(LadleTheme.Label.primary)
                            Spacer()
                            Text(row.count.formatted())
                                .ladleFont(.metadata)
                                .foregroundStyle(LadleTheme.Label.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: LadleTheme.IconSize.small, weight: .semibold))
                                .foregroundStyle(LadleTheme.Label.secondary)
                        }
                        .frame(minHeight: LadleTheme.Control.primary)
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
                LadleTheme.Surface.raised,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
        }
        .padding(.top, 8)
    }

    private var activeFilters: some View {
        RecipeFilterChipsRow(chips: filterChips)
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

    /// An empty library under a filter has to say which filter emptied it.
    /// A diet is still on from a previous launch, which is exactly the case
    /// where "No recipes found" reads as lost recipes rather than a filter.
    private var emptyState: some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: LadleTheme.IconSize.feature))
                .foregroundStyle(accent.label)
            Text("No recipes found")
                .ladleFont(.section)
                .foregroundStyle(LadleTheme.Label.primary)
            Text(emptyStateMessage)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
                .multilineTextAlignment(.center)
            if viewModel.hasActiveFilters {
                Button("Clear filters", action: viewModel.resetFilters)
                    .buttonStyle(LadleButtonStyle(role: .secondary))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LadleTheme.Spacing.cooking)
        .accessibilityIdentifier("library.no-recipes")
    }

    private var emptyStateMessage: String {
        let summary = viewModel.filters.filter.summary
        if !summary.isEmpty {
            return "Nothing in your library matches \(summary)."
        }
        if viewModel.hasActiveFilters {
            return "Nothing in your library matches these filters."
        }
        return "Try another filter or return to all recipes."
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
        LibraryFilterChip.chips(for: viewModel)
    }

    private func controlIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: LadleTheme.IconSize.small, weight: .semibold))
            .foregroundStyle(LadleTheme.Label.primary)
            .frame(width: LadleTheme.Control.hitTarget, height: LadleTheme.Control.hitTarget)
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
        viewModel.displayMode.systemImage
    }

    private var displayModeTitle: String {
        viewModel.displayMode.title
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

    /// Hidden while the cook is looking for something in particular, and
    /// not merely because a diet is on. `filterChips` would have counted
    /// the diet — which survives launches — so setting one would have taken
    /// the Collections card away for good.
    private var showsCollections: Bool {
        viewModel.searchText.isEmpty
            && viewModel.selectedCollection == .all
            && !viewModel.hasBrowsingFilters
    }
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

/// `RecipeSort` is a LadleCore query value and carries no presentation, so
/// how the library names and draws each order lives here, beside its only
/// call site.
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

    var librarySystemImage: String {
        switch self {
        case .recentlyAdded: "clock"
        case .cookingTime: "timer"
        case .highestProtein: "bolt"
        case .calories: "flame"
        case .alphabetical: "textformat.abc"
        }
    }
}

extension LibraryDisplayMode {
    var title: String {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        case .gallery: "Gallery"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        case .gallery: "photo.on.rectangle.angled"
        }
    }
}
