import LadleCore
import SwiftUI

enum LibraryNavigationDestination: Hashable {
    case search
    case importInbox
    case watch
    case recipe(LibraryRecipeDestination)
}

struct LibraryNavigationState: Equatable {
    var path: [LibraryNavigationDestination] = []

    mutating func open(_ destination: LibraryNavigationDestination) {
        path.append(destination)
    }

    mutating func reviewDidComplete(hasActionableImports: Bool) {
        path = hasActionableImports ? [.importInbox] : []
    }
}

struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    @Bindable var importCoordinator: ImportCoordinator
    let accountSession: AccountSession
    var discoverService: any DiscoverServing = DemoDiscoverService()
    var installationID: String = "preview-installation"
    var canImport = true
    var onSignOut: @MainActor () async -> Void = {}
    var onDeleteAccount: @MainActor () async throws -> Void = {}

    @State private var section: LibrarySection = .home
    @State private var isFilterSheetPresented = false
    @State private var isAddSheetPresented = false
    @State private var navigation = LibraryNavigationState()
    @State private var isAccountPresented = false
    @State private var failedImportJob: ImportJob?
    @State private var pendingDestination: LibraryRecipeDestination?
    @State private var discoverImportURL: URL?

    var body: some View {
        NavigationStack(path: $navigation.path) {
            VStack(spacing: 0) {
                LibraryTopBar(
                    openSearch: { navigation.open(.search) },
                    openAccount: { isAccountPresented = true },
                    addRecipe: { presentAddRecipe() },
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
                    discoverImportURL = nil
                }
            ) {
                AddRecipeSheet(
                    coordinator: importCoordinator,
                    accountSession: accountSession,
                    initialLink: discoverImportURL?.absoluteString ?? "",
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
            .navigationDestination(for: LibraryNavigationDestination.self) {
                destination in
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
                case let .recipe(destination):
                    recipeDetail(destination)
                }
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
        .sensoryFeedback(.selection, trigger: section)
        .sensoryFeedback(
            .impact(weight: .light, intensity: 0.65),
            trigger: navigation.path.count
        ) { oldCount, newCount in
            LadleFeedbackPolicy.didPush(
                from: oldCount,
                to: newCount
            )
        }
        .sensoryFeedback(
            .error,
            trigger: viewModel.operationErrorMessage
        ) { oldMessage, newMessage in
            newMessage != nil && newMessage != oldMessage
        }
    }

    @ViewBuilder
    private var content: some View {
        if section == .discover {
            DiscoverView(
                service: discoverService,
                saveRecipe: { recipe in
                    presentAddRecipe(url: recipe.originalURL)
                }
            )
        } else {
            switch viewModel.loadState {
            case .idle:
                LibraryLoadStateView(message: nil, retry: viewModel.load)
            case let .failed(message):
                LibraryLoadStateView(message: message, retry: viewModel.load)
            case .loaded:
                if section == .home {
                    LibraryHomeView(
                        viewModel: viewModel,
                        addRecipe: { presentAddRecipe() },
                        openRecipe: openRecipe,
                        openCollection: openCollection,
                        openImportInbox: {
                            navigation.open(.importInbox)
                        },
                        openWatch: { navigation.open(.watch) }
                    )
                } else {
                    AllRecipesView(
                        viewModel: viewModel,
                        addRecipe: { presentAddRecipe() },
                        openRecipe: openRecipe,
                        presentFilters: { isFilterSheetPresented = true }
                    )
                }
            }
        }
    }

    private func presentAddRecipe(url: URL? = nil) {
        discoverImportURL = url
        isAddSheetPresented = true
    }

    private func recipeDetail(
        _ destination: LibraryRecipeDestination
    ) -> some View {
        RecipeDetailView(
            recipe: destination.recipe,
            statusText: destination.statusText,
            importCoordinator: importCoordinator,
            makeEditorViewModel: viewModel.makeEditorViewModel,
            recipeDidChange: { _ in
                viewModel.load()
            },
            reviewDidComplete: finishReviewNavigation,
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
        navigation.open(
            .recipe(
                .init(
                    recipe: recipe,
                    statusText: statusText
                )
            )
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
            navigation.open(.recipe(destination))
        }
    }

    private func finishReviewNavigation() {
        let hasActionableImports =
            !viewModel.actionableImportJobs.isEmpty
        navigation.reviewDidComplete(
            hasActionableImports: hasActionableImports
        )
        if !hasActionableImports {
            section = .home
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
