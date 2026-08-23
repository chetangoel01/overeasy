import LadleCore
import SwiftUI

enum LibraryNavigationDestination: Hashable {
    case recipe(LibraryRecipeDestination)
}

enum LibraryTab: Hashable, CaseIterable {
    case recipes
    case discover
    case watch
    case inbox
}

enum LibraryToolbarAction: Hashable {
    case account
    case addRecipe
}

struct LibraryNavigationState: Equatable {
    var tab: LibraryTab = .recipes
    var path: [LibraryNavigationDestination] = []

    mutating func open(_ destination: LibraryNavigationDestination) {
        path.append(destination)
    }

    mutating func select(_ tab: LibraryTab) {
        self.tab = tab
        path = []
    }

    mutating func reviewDidComplete(hasActionableImports: Bool) {
        tab = hasActionableImports ? .inbox : .recipes
        path = []
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

    @State private var isFilterSheetPresented = false
    @State private var isAddSheetPresented = false
    @State private var navigation = LibraryNavigationState()
    @State private var isAccountPresented = false
    @State private var failedImportJob: ImportJob?
    @State private var pendingDestination: LibraryRecipeDestination?

    var body: some View {
        NavigationStack(path: $navigation.path) {
            TabView(selection: $navigation.tab) {
                recipes
                    .tabItem {
                        Label("Recipes", systemImage: "book.closed")
                    }
                    .tag(LibraryTab.recipes)

                DiscoverView(
                    service: discoverService,
                    saveRecipe: { saved in
                        viewModel.storeDiscoveredRecipe(saved)
                    }
                )
                .tabItem {
                    Label("Discover", systemImage: "sparkles")
                }
                .tag(LibraryTab.discover)

                WatchView(
                    viewModel: viewModel,
                    openRecipe: openRecipe
                )
                .tabItem {
                    Label("Watch", systemImage: "play.rectangle")
                }
                .tag(LibraryTab.watch)

                ImportInboxView(
                    viewModel: viewModel,
                    recoverImport: { failedImportJob = $0 },
                    openReview: showRecipe
                )
                .tabItem {
                    Label("Inbox", systemImage: "tray")
                }
                .badge(viewModel.importAttentionCount)
                .tag(LibraryTab.inbox)
            }
            .background(LadleTheme.paper)
            .tint(LadleTheme.brick)
            .navigationTitle(navigation.tab.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ForEach(navigation.tab.toolbarActions, id: \.self) {
                        action in
                        switch action {
                        case .account:
                            Button {
                                isAccountPresented = true
                            } label: {
                                Image(systemName: "person.crop.circle")
                            }
                            .accessibilityLabel("Account")
                        case .addRecipe:
                            Button {
                                isAddSheetPresented = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(
                                        .system(size: 20, weight: .semibold)
                                    )
                            }
                            .accessibilityLabel("Add recipe")
                            .disabled(!canImport)
                        }
                    }
                }
            }
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
            .navigationDestination(for: LibraryNavigationDestination.self) {
                destination in
                switch destination {
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
        .sensoryFeedback(.selection, trigger: navigation.tab)
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
    private var recipes: some View {
        switch viewModel.loadState {
        case .idle:
            LibraryLoadStateView(message: nil, retry: viewModel.load)
        case let .failed(message):
            LibraryLoadStateView(message: message, retry: viewModel.load)
        case .loaded:
            AllRecipesView(
                viewModel: viewModel,
                addRecipe: { presentAddRecipe() },
                openRecipe: openRecipe,
                openCollection: openCollection,
                presentFilters: { isFilterSheetPresented = true }
            )
        }
    }

    private func presentAddRecipe() {
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
        navigation.select(.recipes)
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
    }

    private var operationErrorIsPresented: Binding<Bool> {
        Binding(
            get: { viewModel.operationErrorMessage != nil },
            set: { if !$0 { viewModel.clearOperationError() } }
        )
    }
}

private struct LibraryLoadStateView: View {
    let message: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if let message {
                Image(systemName: "fork.knife.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(LadleTheme.accentText)
                Text("Couldn’t load recipes")
                    .ladleFont(.section)
                    .foregroundStyle(LadleTheme.ink)
                Text(message)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.mutedInk)
                    .multilineTextAlignment(.center)
                Button("Try Again", action: retry)
                    .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
            } else {
                ProgressView("Loading recipes")
                    .tint(LadleTheme.brick)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(LadleTheme.paper)
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

extension LibraryTab {
    var title: String {
        switch self {
        case .recipes: "Recipes"
        case .discover: "Discover"
        case .watch: "Watch"
        case .inbox: "Inbox"
        }
    }

    var toolbarActions: [LibraryToolbarAction] {
        self == .recipes ? [.account, .addRecipe] : [.account]
    }
}
