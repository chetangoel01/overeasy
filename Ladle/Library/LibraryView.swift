import LadleCore
import SwiftUI

struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var viewModel: LibraryViewModel
    @Bindable var importCoordinator: ImportCoordinator
    let accountSession: AccountSession

    @State private var isFilterSheetPresented = false
    @State private var isAddSheetPresented = false
    @State private var failedImportJob: ImportJob?
    @State private var selectedDestination: LibraryRecipeDestination?
    @State private var pendingDestination: LibraryRecipeDestination?
    @State private var topSafeAreaInset: CGFloat = 0
    @FocusState private var isSearchFocused: Bool

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: LadleTheme.Spacing.regular),
            GridItem(.flexible(), spacing: LadleTheme.Spacing.regular),
        ]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        libraryHeader
                        searchField
                        controlBar
                        loadContent
                    }
                    .padding(.horizontal, LadleTheme.Spacing.regular)
                    .padding(.bottom, 44)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
            }
            .background(LadleTheme.paper)
            .toolbar(.hidden, for: .navigationBar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.root")
            .task {
                if viewModel.loadState == .idle {
                    viewModel.load()
                }
            }
            .sheet(isPresented: $isFilterSheetPresented) {
                FilterSheet(viewModel: viewModel)
            }
            .sheet(
                isPresented: $isAddSheetPresented,
                onDismiss: {
                    viewModel.load()
                    finishPendingNavigation()
                }
            ) {
                AddRecipeSheet(
                    coordinator: importCoordinator,
                    accountSession: accountSession,
                    viewRecipe: queueNavigation
                )
            }
            .sheet(
                item: $failedImportJob,
                onDismiss: finishPendingNavigation
            ) { job in
                FailedImportSheet(
                    job: job,
                    coordinator: importCoordinator,
                    viewRecipe: queueNavigation
                )
            }
            .navigationDestination(
                item: $selectedDestination
            ) { destination in
                RecipeDetailView(
                    recipe: destination.recipe,
                    statusText: destination.statusText,
                    importCoordinator: importCoordinator,
                    makeEditorViewModel: { recipe in
                        viewModel.makeEditorViewModel(for: recipe)
                    },
                    recipeDidChange: { recipe in
                        selectedDestination = LibraryRecipeDestination(
                            recipe: recipe,
                            statusText: destination.statusText
                        )
                        viewModel.load()
                    },
                    toggleFavorite: { recipeID in
                        viewModel.toggleFavorite(recipeID: recipeID)
                    },
                    deleteRecipe: { recipeID in
                        viewModel.deleteRecipe(recipeID: recipeID)
                    }
                )
            }
            .onChange(of: importCoordinator.state) { _, state in
                switch state {
                case .importing, .completed, .needsReview, .failed:
                    viewModel.load()
                case .idle, .validationFailed, .duplicate, .guestLimit,
                     .persistenceFailed:
                    break
                }
            }
            .alert(
                "Couldn’t update favorite",
                isPresented: operationErrorIsPresented
            ) {
                Button("OK") {
                    viewModel.clearOperationError()
                }
            } message: {
                Text(
                    viewModel.operationErrorMessage
                        ?? "Please try again."
                )
            }
        }
        .overlay(alignment: .top) {
            LadleTheme.paper
                .frame(height: topSafeAreaInset)
                .offset(y: -topSafeAreaInset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onAppear {
            topSafeAreaInset = currentWindowTopSafeAreaInset
        }
    }

    private var libraryHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LADLE")
                    .ladleFont(.eyebrow)
                    .tracking(1.8)
                    .foregroundStyle(LadleTheme.paprika)
                Text("My Recipes")
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.ink)
            }

            Spacer()

            Button {
                isAddSheetPresented = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .background(LadleTheme.paprika, in: Circle())
            }
            .accessibilityLabel("Add Recipe")
        }
        .padding(.top, 18)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LadleTheme.ink.opacity(0.46))
                .accessibilityHidden(true)

            TextField(
                "Search your recipes",
                text: $viewModel.searchText
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.ink)
            .focused($isSearchFocused)
            .submitLabel(.search)
            .frame(minHeight: 44)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .accessibilityLabel("Search your recipes")

            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(LadleTheme.ink.opacity(0.38))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Clear recipe search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(
            LadleTheme.field,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
        )
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        title: viewModel.sort.libraryTitle,
                        systemImage: "arrow.up.arrow.down"
                    )
                }
                .accessibilityLabel("Sort recipes")

                Button {
                    isFilterSheetPresented = true
                } label: {
                    controlLabel(
                        title: filterButtonTitle,
                        systemImage: "line.3.horizontal.decrease"
                    )
                }
                .accessibilityLabel("Filter recipes")

                Spacer()

                Button {
                    let newMode: LibraryDisplayMode =
                        viewModel.displayMode == .grid ? .list : .grid
                    if reduceMotion {
                        viewModel.displayMode = newMode
                    } else {
                        withAnimation(.snappy(duration: 0.25)) {
                            viewModel.displayMode = newMode
                        }
                    }
                } label: {
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

            activeFilters
        }
    }

    @ViewBuilder
    private var activeFilters: some View {
        if hasActiveFilters {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    if viewModel.favoritesOnly {
                        activeFilterButton(
                            title: "Favorites",
                            action: viewModel.removeFavoritesFilter
                        )
                    }
                    if let maximumTotalMinutes = viewModel.maximumTotalMinutes {
                        activeFilterButton(
                            title: "Up to \(maximumTotalMinutes) min",
                            action: viewModel.removeMaximumTimeFilter
                        )
                    }
                    if let maximumCalories = viewModel.maximumCalories {
                        activeFilterButton(
                            title: "Up to \(maximumCalories.formatted()) cal",
                            action: viewModel.removeMaximumCaloriesFilter
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var loadContent: some View {
        switch viewModel.loadState {
        case .idle:
            HStack {
                Spacer()
                ProgressView("Loading recipes")
                    .tint(LadleTheme.paprika)
                Spacer()
            }
            .padding(.top, 40)
        case .loaded:
            loadedContent
        case let .failed(message):
            VStack(spacing: 14) {
                Image(systemName: "fork.knife.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(LadleTheme.paprika)
                Text(message)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                Button("Try Again") {
                    viewModel.load()
                }
                .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
            }
            .padding(.top, 28)
        }
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.generous) {
            if !viewModel.actionableImportJobs.isEmpty {
                importsSection
            }
            recipesSection
        }
    }

    private var importsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(
                title: "Imports",
                detail: "\(viewModel.actionableImportJobs.count) pending"
            )

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(viewModel.actionableImportJobs) { job in
                        if case .failed = job.status {
                            Button {
                                failedImportJob = job
                            } label: {
                                PendingImportCard(job: job)
                            }
                            .buttonStyle(.plain)
                        } else {
                            PendingImportCard(job: job)
                        }
                    }
                }
            }
            .contentMargins(.horizontal, 1, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }

    private var recipesSection: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.regular) {
            LadleSectionHeader(
                title: viewModel.sort.librarySectionTitle,
                detail: recipeCountText
            )

            if viewModel.visibleRecipes.isEmpty {
                emptyState
            } else if viewModel.displayMode == .grid {
                LazyVGrid(
                    columns: columns,
                    spacing: LadleTheme.Spacing.generous
                ) {
                    ForEach(viewModel.visibleRecipes) { recipe in
                        RecipeGridCard(
                            recipe: recipe,
                            openRecipe: {
                                openRecipe(recipe)
                            },
                            toggleFavorite: {
                                viewModel.toggleFavorite(recipeID: recipe.id)
                            }
                        )
                    }
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.visibleRecipes) { recipe in
                        RecipeListRow(
                            recipe: recipe,
                            openRecipe: {
                                openRecipe(recipe)
                            },
                            toggleFavorite: {
                                viewModel.toggleFavorite(recipeID: recipe.id)
                            }
                        )
                    }
                }
            }
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
            Text("Try a different search or remove a filter.")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.58))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(LadleTheme.field.opacity(0.7))
        .clipShape(
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    private func controlLabel(
        title: String,
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

    private func activeFilterButton(
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            LadlePill(
                text: title,
                systemImage: "xmark",
                tint: LadleTheme.review
            )
        }
        .accessibilityLabel("Remove filter: \(title)")
    }

    private var hasActiveFilters: Bool {
        viewModel.favoritesOnly
            || viewModel.maximumTotalMinutes != nil
            || viewModel.maximumCalories != nil
    }

    private var filterButtonTitle: String {
        let count = [
            viewModel.favoritesOnly,
            viewModel.maximumTotalMinutes != nil,
            viewModel.maximumCalories != nil,
        ]
        .filter { $0 }
        .count
        return count == 0 ? "Filters" : "Filters \(count)"
    }

    private var recipeCountText: String {
        let count = viewModel.visibleRecipes.count
        return count == 1 ? "1 recipe" : "\(count) recipes"
    }

    private var operationErrorIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.operationErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.clearOperationError()
                }
            }
        )
    }

    private var currentWindowTopSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top
            ?? 0
    }

    private func queueNavigation(
        to recipe: Recipe,
        statusText: String
    ) {
        pendingDestination = LibraryRecipeDestination(
            recipe: recipe,
            statusText: statusText
        )
    }

    private func openRecipe(_ recipe: Recipe) {
        selectedDestination = LibraryRecipeDestination(
            recipe: recipe,
            statusText: "Saved recipe"
        )
    }

    private func finishPendingNavigation() {
        guard let destination = pendingDestination else {
            return
        }
        pendingDestination = nil
        Task { @MainActor in
            await Task.yield()
            selectedDestination = destination
        }
    }
}

private struct LibraryRecipeDestination: Hashable {
    let recipe: Recipe
    let statusText: String
}

extension RecipeSort {
    var libraryTitle: String {
        switch self {
        case .recentlyAdded:
            "Recently added"
        case .cookingTime:
            "Cooking time"
        case .calories:
            "Calories"
        case .alphabetical:
            "A–Z"
        }
    }

    var librarySectionTitle: String {
        switch self {
        case .recentlyAdded:
            "Recently added"
        case .cookingTime:
            "Quickest first"
        case .calories:
            "Lightest first"
        case .alphabetical:
            "All recipes"
        }
    }
}
