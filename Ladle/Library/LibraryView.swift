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
    private var paths: [LibraryTab: [LibraryNavigationDestination]] = [:]

    init(
        tab: LibraryTab = .recipes,
        path: [LibraryNavigationDestination] = []
    ) {
        self.tab = tab
        if !path.isEmpty {
            paths[tab] = path
        }
    }

    /// Each tab keeps its own stack so switching tabs never re-binds a
    /// shared navigation bar to a different tab's scroll view.
    subscript(pathFor tab: LibraryTab) -> [LibraryNavigationDestination] {
        get { paths[tab] ?? [] }
        set { paths[tab] = newValue }
    }

    var path: [LibraryNavigationDestination] {
        get { self[pathFor: tab] }
        set { self[pathFor: tab] = newValue }
    }

    mutating func open(_ destination: LibraryNavigationDestination) {
        path.append(destination)
    }

    mutating func select(_ tab: LibraryTab) {
        self.tab = tab
        paths[tab] = []
    }

    mutating func reviewDidComplete(hasActionableImports: Bool) {
        tab = hasActionableImports ? .inbox : .recipes
        paths = [:]
    }
}

enum LibraryWorkspacePresentation: Equatable {
    case loading
    case blockingFailure(String)
    case content(reloadError: String?)

    init(
        loadState: LibraryViewModel.LoadState,
        reloadErrorMessage: String?
    ) {
        switch loadState {
        case .idle:
            self = .loading
        case let .failed(message):
            self = .blockingFailure(message)
        case .loaded:
            self = .content(reloadError: reloadErrorMessage)
        }
    }

    var displaysTabs: Bool {
        guard case .content = self else { return false }
        return true
    }
}

struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    @Bindable var importCoordinator: ImportCoordinator
    let accountSession: AccountSession
    var authClient: AuthClient?
    var googleSignIn: (any GoogleSignInProviding)?
    var discoverService: any DiscoverServing = DemoDiscoverService()
    var syncStatus: SyncStatus = SyncStatus()
    var notificationNavigation: NotificationNavigation = .shared
    var canImport = true
    var onAuthenticated: @MainActor () async -> Void = {}
    var onSignOut: @MainActor () async -> Void = {}
    var onDeleteAccount: @MainActor () async throws -> Void = {}

    @State private var isFilterSheetPresented = false
    @State private var isAddSheetPresented = false
    @State private var navigation = LibraryNavigationState()
    @State private var isAccountPresented = false
    @State private var isConflictReviewPresented = false
    @State private var failedImportJob: ImportJob?
    @State private var pendingDestination: LibraryRecipeDestination?
    @State private var watchRefreshVersion = 0

    var body: some View {
        workspace
            .background(LadleTheme.Surface.porcelain)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.root")
            .task(id: notificationNavigation.recipeID) {
                if viewModel.loadState == .idle {
                    viewModel.load()
                }
                openNotificationRecipeIfNeeded()
            }
            .sheet(isPresented: $isFilterSheetPresented) {
                FilterSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $isAccountPresented) {
                AccountSheet(
                    accountSession: accountSession,
                    library: viewModel,
                    syncStatus: syncStatus,
                    signOut: onSignOut,
                    deleteAccount: onDeleteAccount
                )
            }
            .sheet(isPresented: $isConflictReviewPresented) {
                SyncConflictReviewSheet(
                    conflicts: viewModel.syncConflicts,
                    resolve: viewModel.resolveSyncConflict
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
                    authClient: authClient,
                    googleSignIn: googleSignIn,
                    onAuthenticated: onAuthenticated,
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
            .onChange(of: importCoordinator.state) { _, state in
                if state.refreshesLibrary {
                    viewModel.load()
                }
            }
            .onChange(of: navigation.tab) { oldTab, newTab in
                if newTab == .watch, oldTab != .watch {
                    watchRefreshVersion += 1
                }
            }
            .libraryOperationAlert(
                isPresented: operationErrorIsPresented,
                message: operationErrorText,
                clear: viewModel.clearOperationError
            )
            .sensoryFeedback(.selection, trigger: navigation.tab)
            .sensoryFeedback(
                .impact(weight: .light, intensity: 0.65),
                trigger: navigation,
                condition: isPushWithinTab
            )
            .sensoryFeedback(
                .error,
                trigger: viewModel.operationErrorMessage
            ) { oldMessage, newMessage in
                newMessage != nil && newMessage != oldMessage
            }
    }

    @ViewBuilder
    private var workspace: some View {
        switch workspacePresentation {
        case .loading:
            loadState(message: nil)
        case let .blockingFailure(message):
            loadState(message: message)
        case let .content(reloadError):
            workspaceTabs(reloadError: reloadError)
        }
    }

    private func loadState(message: String?) -> some View {
        NavigationStack {
            LibraryLoadStateView(message: message, retry: viewModel.load)
                .navigationTitle(LibraryTab.recipes.title)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        accountButton
                    }
                }
        }
    }

    private var workspacePresentation: LibraryWorkspacePresentation {
        LibraryWorkspacePresentation(
            loadState: viewModel.loadState,
            reloadErrorMessage: viewModel.reloadErrorMessage
        )
    }

    private func workspaceTabs(reloadError: String?) -> some View {
        TabView(selection: $navigation.tab) {
            recipesTab(reloadError: reloadError)
            discoverTab(reloadError: reloadError)
            watchTab
            inboxTab(reloadError: reloadError)
        }
    }

    /// Banners sit inside each tab's own stack so they render below that
    /// tab's navigation bar rather than above every bar at once.
    @ViewBuilder
    private func banners(reloadError: String?) -> some View {
        VStack(spacing: 0) {
            if let reloadError {
                LibraryReloadErrorBanner(
                    message: reloadError,
                    retry: viewModel.load
                )
            }
            if !viewModel.syncConflicts.isEmpty {
                SyncConflictBanner(
                    count: viewModel.syncConflicts.count,
                    review: { isConflictReviewPresented = true }
                )
            }
            SyncStatusBanner(status: syncStatus)
        }
    }

    /// Per-tab stacks mean the current path count also changes when
    /// switching tabs; only a push inside one tab should feel like a push.
    private func isPushWithinTab(
        _ oldValue: LibraryNavigationState,
        _ newValue: LibraryNavigationState
    ) -> Bool {
        guard oldValue.tab == newValue.tab else { return false }
        return LadleFeedbackPolicy.didPush(
            from: oldValue.path.count,
            to: newValue.path.count
        )
    }

    private func pathBinding(
        for tab: LibraryTab
    ) -> Binding<[LibraryNavigationDestination]> {
        Binding(
            get: { navigation[pathFor: tab] },
            set: { navigation[pathFor: tab] = $0 }
        )
    }

    private var recipes: some View {
        AllRecipesView(
            viewModel: viewModel,
            addRecipe: { presentAddRecipe() },
            openRecipe: openRecipe,
            openCollection: openCollection,
            presentFilters: { isFilterSheetPresented = true }
        )
    }

    private func recipesTab(reloadError: String?) -> some View {
        tabStack(.recipes, reloadError: reloadError) {
            recipes
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        accountButton
                        addRecipeButton
                    }
                }
        }
        .tabItem {
            Label("Recipes", systemImage: "book.closed")
        }
        .tag(LibraryTab.recipes)
    }

    private func discoverTab(reloadError: String?) -> some View {
        tabStack(.discover, reloadError: reloadError) {
            discover
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        accountButton
                    }
                }
        }
        .tabItem {
            Label("Discover", systemImage: "fork.knife")
        }
        .tag(LibraryTab.discover)
    }

    /// One navigation stack per tab: each tab owns its bar, so the large
    /// title is already in place when the tab appears.
    private func tabStack<Content: View>(
        _ tab: LibraryTab,
        reloadError: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack(path: pathBinding(for: tab)) {
            content()
                .safeAreaInset(edge: .top, spacing: 0) {
                    banners(reloadError: reloadError)
                }
                .navigationTitle(tab.title)
                .navigationBarTitleDisplayMode(.large)
                .navigationDestination(
                    for: LibraryNavigationDestination.self
                ) { destination in
                    switch destination {
                    case let .recipe(destination):
                        recipeDetail(destination)
                    }
                }
        }
    }

    private var watchTab: some View {
        NavigationStack(path: pathBinding(for: .watch)) {
            watchContent
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(
                    for: LibraryNavigationDestination.self
                ) { destination in
                    switch destination {
                    case let .recipe(destination):
                        recipeDetail(destination)
                    }
                }
        }
        .tabItem {
            Label("Watch", systemImage: "play.rectangle")
        }
        .tag(LibraryTab.watch)
    }

    private var watchContent: some View {
        WatchView(
            viewModel: viewModel,
            discoverService: discoverService,
            refreshVersion: watchRefreshVersion,
            openSavedRecipe: openRecipe,
            openDiscoverRecipe: { recipe in
                showRecipe(
                    recipe,
                    statusText: "Discover recipe",
                    access: .discover
                )
            },
            saveRecipe: { saved in
                viewModel.storeDiscoveredRecipe(saved)
            }
        )
    }

    private func inboxTab(reloadError: String?) -> some View {
        tabStack(.inbox, reloadError: reloadError) {
            inboxContent
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        accountButton
                        addRecipeButton
                    }
                }
        }
        .tabItem {
            Label("Inbox", systemImage: "tray")
        }
        .badge(viewModel.importAttentionCount)
        .tag(LibraryTab.inbox)
    }

    private var inboxContent: some View {
        ImportInboxView(
            viewModel: viewModel,
            addRecipe: presentAddRecipe,
            recoverImport: { failedImportJob = $0 },
            openProcessing: presentProcessing,
            cancelImport: { jobID in
                Task {
                    await importCoordinator.cancelImport(jobID: jobID)
                    viewModel.load()
                }
            },
            openReview: { recipe, statusText in
                showRecipe(recipe, statusText: statusText)
            },
            operationFailure: importCoordinator.failure,
            canImport: canImport
        )
    }

    private var discover: some View {
        DiscoverView(
            service: discoverService,
            saveRecipe: { saved in
                viewModel.storeDiscoveredRecipe(saved)
            },
            openRecipe: { recipe in
                showRecipe(
                    recipe,
                    statusText: "Discover recipe",
                    access: .discover
                )
            }
        )
    }

    private var accountButton: some View {
        Button {
            isAccountPresented = true
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Settings and account")
    }

    private var addRecipeButton: some View {
        Button {
            isAddSheetPresented = true
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: LadleTheme.IconSize.large, weight: .semibold))
        }
        .accessibilityLabel("Add recipe")
        .disabled(!canImport)
    }

    private func presentAddRecipe() {
        isAddSheetPresented = true
    }

    private func presentProcessing(_ job: ImportJob) {
        guard importCoordinator.attach(to: job.id) else {
            viewModel.load()
            return
        }
        isAddSheetPresented = true
    }

    private func openNotificationRecipeIfNeeded() {
        guard let recipe = notificationNavigation.claimRecipe(
            in: viewModel
        ) else {
            return
        }
        navigation.select(.recipes)
        showRecipe(recipe, statusText: "Imported recipe")
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
            deleteRecipe: viewModel.deleteRecipe,
            access: destination.access,
            openAccount: { isAccountPresented = true }
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
        statusText: String,
        access: LibraryRecipeAccess = .saved
    ) {
        navigation.open(
            .recipe(
                .init(
                    recipe: recipe,
                    statusText: statusText,
                    access: access
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

    private var operationErrorText: String {
        viewModel.operationErrorMessage ?? "Please try again."
    }
}

private struct SyncStatusBanner: View {
    let status: SyncStatus

    @ViewBuilder
    var body: some View {
        switch status.state {
        case .idle, .current:
            EmptyView()
        case .syncing:
            banner(systemImage: nil) {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing recipes…")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.primary)
            }
        case .conflict:
            EmptyView()
        case let .failed(report):
            banner(systemImage: report.failure.systemImage) {
                VStack(
                    alignment: .leading,
                    spacing: LadleTheme.Spacing.tight
                ) {
                    Text(report.failure.title)
                        .ladleFont(.bodyStrong)
                        .foregroundStyle(LadleTheme.Label.primary)
                    Text(report.failure.message)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.Label.secondary)
                    if let retryAt = report.failure.retryAt {
                        Text("Try again after \(retryAt, style: .time).")
                            .ladleFont(.metadata)
                            .foregroundStyle(LadleTheme.Label.secondary)
                    }
                }
            }
        }
    }

    private func banner<Content: View>(
        systemImage: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: LadleTheme.Layout.iconGap) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(
                        size: LadleTheme.IconSize.medium,
                        weight: .semibold
                    ))
                    .foregroundStyle(LadleTheme.Label.primary)
                    .accessibilityHidden(true)
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, LadleTheme.Layout.screenMargin)
        .padding(.vertical, LadleTheme.Spacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LadleTheme.Surface.steel)
        .overlay(alignment: .bottom) {
            Divider().overlay(LadleTheme.Stroke.separator)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sync.status")
    }

}

private struct LibraryReloadErrorBanner: View {
    @Environment(\.ladleAccent) private var accent

    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: LadleTheme.Layout.iconGap) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(
                    size: LadleTheme.IconSize.medium,
                    weight: .semibold
                ))
                .foregroundStyle(LadleTheme.Label.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                Text("Showing saved recipes")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.primary)
                Text(message)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.secondary)
            }
            Spacer(minLength: LadleTheme.Spacing.compact)
            Button("Try Again", action: retry)
                .ladleFont(.bodyStrong)
                .foregroundStyle(accent.label)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, LadleTheme.Layout.screenMargin)
        .padding(.vertical, LadleTheme.Spacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LadleTheme.Surface.steel)
        .overlay(alignment: .bottom) {
            Divider().overlay(LadleTheme.Stroke.separator)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.reload-error")
    }
}

private struct LibraryLoadStateView: View {
    @Environment(\.ladleAccent) private var accent

    let message: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
            if let message {
                Image(systemName: "fork.knife.circle")
                    .font(.system(size: LadleTheme.IconSize.hero))
                    .foregroundStyle(accent.label)
                Text("Couldn’t load recipes")
                    .ladleFont(.section)
                    .foregroundStyle(LadleTheme.Label.primary)
                Text(message)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.Label.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again", action: retry)
                    .buttonStyle(LadleButtonStyle(role: .secondary))
            } else {
                ProgressView("Loading recipes")
                    .tint(accent.intent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(LadleTheme.Surface.porcelain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.load-state")
    }
}

struct LibraryRecipeDestination: Hashable {
    let recipe: Recipe
    let statusText: String
    let access: LibraryRecipeAccess

    init(
        recipe: Recipe,
        statusText: String,
        access: LibraryRecipeAccess = .saved
    ) {
        self.recipe = recipe
        self.statusText = statusText
        self.access = access
    }
}

enum LibraryRecipeAccess: Hashable {
    case saved
    case discover
}

extension NotificationNavigation {
    /// Claims the recipe a tapped import-ready notification points at,
    /// consuming the pending navigation on every path.
    ///
    /// An import job the coordinator does not own (a share-extension job
    /// resumed in the background) saves its recipe durably and posts the
    /// banner without touching the published import state, so the
    /// in-memory library can be stale when the tap lands — reload once
    /// before deciding the recipe is gone. And the claim must consume
    /// `recipeID` even when no recipe matches: left set, a failed match
    /// pins `.task(id:)` on an unchanged value and permanently swallows
    /// every later tap for that recipe.
    func claimRecipe(in library: LibraryViewModel) -> Recipe? {
        guard let recipeID else { return nil }
        defer { clear() }
        if let recipe = library.recipes.first(
            where: { $0.id == recipeID }
        ) {
            return recipe
        }
        library.load()
        return library.recipes.first { $0.id == recipeID }
    }
}

private extension View {
    func libraryOperationAlert(
        isPresented: Binding<Bool>,
        message: String,
        clear: @escaping () -> Void
    ) -> some View {
        alert(
            "Couldn’t update library",
            isPresented: isPresented
        ) {
            Button("OK", action: clear)
        } message: {
            Text(message)
        }
    }
}

private extension ImportCoordinatorState {
    var refreshesLibrary: Bool {
        switch self {
        case .importing, .completed, .needsReview, .failed, .cancelled:
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
        [.recipes, .inbox].contains(self)
            ? [.account, .addRecipe]
            : [.account]
    }
}
