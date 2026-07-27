import LadleCore
import SwiftUI

private enum LibraryWorkspaceDestination: Hashable, Identifiable {
    case search
    case importInbox
    case watch

    var id: Self { self }
}

struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    @Bindable var importCoordinator: ImportCoordinator
    let accountSession: AccountSession
    var installationID: String = "preview-installation"
    var canImport = true
    var onSignOut: @MainActor () async -> Void = {}
    var onDeleteAccount: @MainActor () async throws -> Void = {}

    @State private var section: LibrarySection = .home
    @State private var isFilterSheetPresented = false
    @State private var isAddSheetPresented = false
    @State private var workspaceDestination: LibraryWorkspaceDestination?
    @State private var isAccountPresented = false
    @State private var failedImportJob: ImportJob?
    @State private var selectedDestination: LibraryRecipeDestination?
    @State private var pendingDestination: LibraryRecipeDestination?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LibraryTopBar(
                    openSearch: { workspaceDestination = .search },
                    openAccount: { isAccountPresented = true },
                    addRecipe: { isAddSheetPresented = true },
                    isAddEnabled: canImport
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
            .sheet(isPresented: $isAccountPresented) {
                AccountSheet(
                    accountSession: accountSession,
                    library: viewModel,
                    installationID: installationID,
                    signOut: onSignOut,
                    deleteAccount: onDeleteAccount
                )
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
                    currentRecipe: viewModel.recipeForReview(job),
                    coordinator: importCoordinator,
                    viewRecipe: { recipe, statusText in
                        viewModel.load()
                        queueNavigation(
                            to: recipe,
                            statusText: statusText
                        )
                    }
                )
            }
            .navigationDestination(item: $workspaceDestination) { destination in
                switch destination {
                case .search:
                    LibrarySearchView(
                        viewModel: viewModel,
                        openRecipe: openRecipe
                    )
                case .importInbox:
                    ImportInboxView(
                        viewModel: viewModel,
                        recoverImport: { failedImportJob = $0 },
                        openReview: showRecipe
                    )
                case .watch:
                    WatchView(
                        viewModel: viewModel,
                        openRecipe: openRecipe
                    )
                }
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
                "Couldn’t update library",
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
                    addRecipe: { isAddSheetPresented = true },
                    openRecipe: openRecipe,
                    openCollection: openCollection,
                    openImportInbox: {
                        workspaceDestination = .importInbox
                    },
                    openWatch: { workspaceDestination = .watch }
                )
            } else {
                AllRecipesView(
                    viewModel: viewModel,
                    addRecipe: { isAddSheetPresented = true },
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
            toggleFavorite: viewModel.toggleFavorite,
            completeReview: viewModel.completeReview,
            deleteRecipe: viewModel.deleteRecipe
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
