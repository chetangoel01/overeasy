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
    var discoverService: any DiscoverServing = DemoDiscoverService()
    var syncStatus: SyncStatus = SyncStatus()
    var installationID: String = "preview-installation"
    var notificationNavigation: NotificationNavigation = .shared
    var canImport = true
    var onSignOut: @MainActor () async -> Void = {}
    var onDeleteAccount: @MainActor () async throws -> Void = {}

    @State private var isFilterSheetPresented = false
    @State private var isAddSheetPresented = false
    @State private var navigation = LibraryNavigationState()
    @State private var isAccountPresented = false
    @State private var failedImportJob: ImportJob?
    @State private var pendingDestination: LibraryRecipeDestination?
    @State private var watchRefreshVersion = 0

    var body: some View {
        NavigationStack(path: $navigation.path) {
            workspace
            .background(LadleTheme.paper)
            .tint(LadleTheme.brick)
            .navigationTitle(navigation.tab.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar(
                navigation.tab == .watch
                    ? .hidden
                    : .visible,
                for: .navigationBar
            )
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    accountButton
                    if workspacePresentation.displaysTabs,
                       navigation.tab == .recipes {
                        addRecipeButton
                    }
                }
            }
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
    private var workspace: some View {
        switch workspacePresentation {
        case .loading:
            LibraryLoadStateView(message: nil, retry: viewModel.load)
        case let .blockingFailure(message):
            LibraryLoadStateView(message: message, retry: viewModel.load)
        case let .content(reloadError):
            workspaceTabs(reloadError: reloadError)
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
            recipesTab
            discoverTab
            watchTab
            inboxTab
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let reloadError {
                    LibraryReloadErrorBanner(
                        message: reloadError,
                        retry: viewModel.load
                    )
                }
                SyncStatusBanner(status: syncStatus)
            }
        }
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

    private var recipesTab: some View {
        recipes
            .tabItem {
                Label("Recipes", systemImage: "book.closed")
            }
            .tag(LibraryTab.recipes)
    }

    private var discoverTab: some View {
        discover
            .tabItem {
                Label("Discover", systemImage: "fork.knife")
            }
            .tag(LibraryTab.discover)
    }

    private var watchTab: some View {
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
            },
            openAccount: { isAccountPresented = true }
        )
        .tabItem {
            Label("Watch", systemImage: "play.rectangle")
        }
        .tag(LibraryTab.watch)
    }

    private var inboxTab: some View {
        ImportInboxView(
            viewModel: viewModel,
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
            operationFailure: importCoordinator.failure
        )
        .tabItem {
            Label("Inbox", systemImage: "tray")
        }
        .badge(viewModel.importAttentionCount)
        .tag(LibraryTab.inbox)
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
                .font(.system(size: 20, weight: .semibold))
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
        guard let recipeID = notificationNavigation.recipeID,
              let recipe = viewModel.recipes.first(
                  where: { $0.id == recipeID }
              ) else {
            return
        }
        navigation.select(.recipes)
        showRecipe(recipe, statusText: "Imported recipe")
        notificationNavigation.clear()
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
            allowsLibraryEdits: destination.allowsLibraryEdits,
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
                .foregroundStyle(LadleTheme.accentText)
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
    let message: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
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
                    .buttonStyle(LadleButtonStyle(role: .secondary))
            } else {
                ProgressView("Loading recipes")
                    .tint(LadleTheme.brick)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .background(LadleTheme.paper)
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

    var allowsLibraryEdits: Bool { access == .saved }
}

enum LibraryRecipeAccess: Hashable {
    case saved
    case discover
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
