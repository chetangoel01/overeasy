import LadleCore
import SwiftUI

struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    @Bindable var importCoordinator: ImportCoordinator
    let accountSession: AccountSession

    @State private var section: LibrarySection = .home
    @State private var isFilterSheetPresented = false
    @State private var isAddSheetPresented = false
    @State private var isSearchPresented = false
    @State private var isImportInboxPresented = false
    @State private var isWatchPresented = false
    @State private var failedImportJob: ImportJob?
    @State private var selectedDestination: LibraryRecipeDestination?
    @State private var pendingDestination: LibraryRecipeDestination?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LibraryTopBar(
                    openSearch: { isSearchPresented = true },
                    addRecipe: { isAddSheetPresented = true }
                )
                LibrarySectionPicker(
                    selection: $section,
                    recipeCount: viewModel.recipes.count
                )
                content
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
                onDismiss: finishPendingNavigation
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
            .navigationDestination(isPresented: $isSearchPresented) {
                LibrarySearchView(
                    viewModel: viewModel,
                    openRecipe: openRecipe
                )
            }
            .navigationDestination(isPresented: $isImportInboxPresented) {
                ImportInboxView(
                    viewModel: viewModel,
                    recoverImport: { failedImportJob = $0 },
                    openReview: showRecipe
                )
            }
            .navigationDestination(isPresented: $isWatchPresented) {
                WatchView(
                    viewModel: viewModel,
                    openRecipe: openRecipe
                )
            }
            .navigationDestination(item: $selectedDestination) { destination in
                recipeDetail(destination)
            }
            .onChange(of: importCoordinator.state) { _, state in
                if state.refreshesLibrary {
                    viewModel.load()
                }
            }
            .alert(
                "Couldn’t update favorite",
                isPresented: operationErrorIsPresented
            ) {
                Button("OK", action: viewModel.clearOperationError)
            } message: {
                Text(viewModel.operationErrorMessage ?? "Please try again.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle:
            LibraryLoadStateView(message: nil, retry: viewModel.load)
        case let .failed(message):
            LibraryLoadStateView(message: message, retry: viewModel.load)
        case .loaded:
            if section == .home {
                LibraryHomeView(
                    viewModel: viewModel,
                    openRecipe: openRecipe,
                    openCollection: openCollection,
                    openImportInbox: {
                        isImportInboxPresented = true
                    },
                    openWatch: { isWatchPresented = true }
                )
            } else {
                AllRecipesView(
                    viewModel: viewModel,
                    openRecipe: openRecipe,
                    presentFilters: { isFilterSheetPresented = true }
                )
            }
        }
    }

    private func recipeDetail(
        _ destination: LibraryRecipeDestination
    ) -> some View {
        RecipeDetailView(
            recipe: destination.recipe,
            statusText: destination.statusText,
            importCoordinator: importCoordinator,
            makeEditorViewModel: viewModel.makeEditorViewModel,
            recipeDidChange: { recipe in
                selectedDestination = .init(
                    recipe: recipe,
                    statusText: destination.statusText
                )
                viewModel.load()
            },
            toggleFavorite: viewModel.toggleFavorite
        )
    }

    private func openCollection(_ collection: LibraryRecipeCollection) {
        viewModel.showCollection(collection)
        section = .all
    }

    private func openRecipe(_ recipe: Recipe) {
        showRecipe(recipe, statusText: "Saved recipe")
    }

    private func showRecipe(
        _ recipe: Recipe,
        statusText: String
    ) {
        selectedDestination = .init(
            recipe: recipe,
            statusText: statusText
        )
    }

    private func queueNavigation(
        to recipe: Recipe,
        statusText: String
    ) {
        pendingDestination = .init(
            recipe: recipe,
            statusText: statusText
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

    private var operationErrorIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.operationErrorMessage != nil },
            set: { if !$0 { viewModel.clearOperationError() } }
        )
    }
}

struct LibraryRecipeDestination: Hashable {
    let recipe: Recipe
    let statusText: String
}

private extension ImportCoordinatorState {
    var refreshesLibrary: Bool {
        switch self {
        case .importing, .completed, .needsReview, .failed:
            true
        case .idle, .validationFailed, .duplicate, .guestLimit,
             .persistenceFailed:
            false
        }
    }
}
