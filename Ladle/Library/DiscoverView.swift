import LadleCore
import Observation
import SwiftUI

@MainActor
@Observable
final class DiscoverViewModel {
    enum State: Equatable {
        case idle
        case loading
        case loaded([DiscoverRecipe])
        case failed(RemoteFailureReport)
    }

    enum RefreshState: Equatable {
        case current
        case refreshing
        case failed(RemoteFailureReport)
    }

    private let service: any DiscoverServing
    private let removesSavedRecipeImmediately: Bool
    private(set) var state: State = .idle
    private(set) var refreshState: RefreshState = .current
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private var nextCursor = 0
    /// Bumped on every query or sort change. A page that finishes after the
    /// criteria moved on carries a stale generation and is discarded, so a
    /// slow first page cannot overwrite the results of a later search.
    private var generation = 0

    private var reloadTask: Task<Void, Never>?

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            criteriaChanged()
            // Typing is a round trip now, so wait for a pause.
            scheduleReload(after: .milliseconds(300))
        }
    }

    var sort: DiscoverSort = .popular {
        didSet {
            guard sort != oldValue else { return }
            criteriaChanged()
            scheduleReload(after: .zero)
        }
    }

    /// Reloading belongs to the criteria changing, not to the view appearing.
    /// It used to hang off `.task(id:)`, which SwiftUI also runs every time
    /// the view comes back — so every switch back to Discover threw the feed
    /// away and showed a spinner.
    private func scheduleReload(after delay: Duration) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.load()
        }
    }
    private(set) var savingSourceIDs: Set<UUID> = []
    private(set) var loadingDetailSourceIDs: Set<UUID> = []
    private(set) var savedSourceIDs: Set<UUID> = []
    private var saveFailures: [UUID: RemoteFailureReport] = [:]
    private var detailFailures: [UUID: RemoteFailureReport] = [:]

    init(
        service: any DiscoverServing,
        removesSavedRecipeImmediately: Bool = true
    ) {
        self.service = service
        self.removesSavedRecipeImmediately = removesSavedRecipeImmediately
    }

    private func criteriaChanged() {
        generation += 1
        nextCursor = 0
        hasMore = false
        state = .loading
    }

    /// Loads the first page for the current query and sort, replacing
    /// whatever is on screen. Also the refresh path.
    func load() async {
        guard refreshState != .refreshing else { return }
        let token = generation
        let cachedRecipes: [DiscoverRecipe]?
        if case let .loaded(recipes) = state, !recipes.isEmpty {
            cachedRecipes = recipes
            refreshState = .refreshing
        } else {
            cachedRecipes = nil
            state = .loading
        }
        do {
            let page = try await service.fetchDiscoverPage(
                cursor: 0,
                query: query,
                sort: sort
            )
            guard token == generation else { return }
            savedSourceIDs = Set(
                page.recipes.lazy.compactMap { recipe in
                    recipe.savedRecipeID == nil ? nil : recipe.sourceID
                }
            )
            nextCursor = page.nextCursor
            hasMore = page.hasMore
            state = .loaded(page.recipes.filter { $0.savedRecipeID == nil })
            refreshState = .current
        } catch is CancellationError {
            guard token == generation else { return }
            if let cachedRecipes {
                state = .loaded(cachedRecipes)
                refreshState = .current
            } else {
                state = .idle
            }
        } catch {
            guard token == generation else { return }
            let report = RemoteFailureReport(error)
            if let cachedRecipes {
                state = .loaded(cachedRecipes)
                refreshState = .failed(report)
            } else {
                state = .failed(report)
            }
        }
    }

    /// Appends the next page. A failure here leaves the rows already on
    /// screen alone — the reader keeps what they have and can scroll again.
    func loadMore() async {
        guard hasMore, !isLoadingMore, refreshState != .refreshing,
              case let .loaded(existing) = state
        else { return }
        let token = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await service.fetchDiscoverPage(
                cursor: nextCursor,
                query: query,
                sort: sort
            )
            guard token == generation, case .loaded = state else { return }
            let seen = Set(existing.map(\.sourceID))
            let fresh = page.recipes.filter {
                $0.savedRecipeID == nil
                    && !seen.contains($0.sourceID)
                    && !savedSourceIDs.contains($0.sourceID)
            }
            nextCursor = page.nextCursor
            hasMore = page.hasMore
            state = .loaded(existing + fresh)
        } catch is CancellationError {
            return
        } catch {
            guard token == generation else { return }
            // Stop walking rather than retrying the same cursor forever.
            hasMore = false
        }
    }

    /// True once the reader is close enough to the end to start the next page.
    func shouldLoadMore(after recipe: DiscoverRecipe) -> Bool {
        guard hasMore, !isLoadingMore, case let .loaded(recipes) = state,
              let index = recipes.firstIndex(where: {
                  $0.sourceID == recipe.sourceID
              })
        else { return false }
        return index >= recipes.count - DiscoverPaging.prefetchThreshold
    }

    func isSaving(_ recipe: DiscoverRecipe) -> Bool {
        savingSourceIDs.contains(recipe.sourceID)
    }

    func isSaved(_ recipe: DiscoverRecipe) -> Bool {
        savedSourceIDs.contains(recipe.sourceID)
            || recipe.savedRecipeID != nil
    }

    func isLoadingDetail(_ recipe: DiscoverRecipe) -> Bool {
        loadingDetailSourceIDs.contains(recipe.sourceID)
    }

    func saveFailure(for recipe: DiscoverRecipe) -> RemoteFailureReport? {
        saveFailures[recipe.sourceID]
    }

    func detailFailure(for recipe: DiscoverRecipe) -> RemoteFailureReport? {
        detailFailures[recipe.sourceID]
    }

    func detail(for recipe: DiscoverRecipe) async -> Recipe? {
        guard !isLoadingDetail(recipe) else { return nil }
        detailFailures[recipe.sourceID] = nil
        loadingDetailSourceIDs.insert(recipe.sourceID)
        defer { loadingDetailSourceIDs.remove(recipe.sourceID) }
        do {
            let detail = try await service.fetchDiscoverRecipe(
                sourceID: recipe.sourceID
            )
            return detail
        } catch is CancellationError {
            return nil
        } catch {
            detailFailures[recipe.sourceID] = RemoteFailureReport(error)
            return nil
        }
    }

    func save(
        _ recipe: DiscoverRecipe
    ) async -> SavedDiscoverRecipe? {
        guard !isSaving(recipe), !isSaved(recipe) else {
            return nil
        }
        saveFailures[recipe.sourceID] = nil
        savingSourceIDs.insert(recipe.sourceID)
        defer { savingSourceIDs.remove(recipe.sourceID) }
        do {
            let saved = try await service.saveDiscoverRecipe(
                sourceID: recipe.sourceID
            )
            savedSourceIDs.insert(recipe.sourceID)
            if removesSavedRecipeImmediately,
               case let .loaded(recipes) = state {
                state = .loaded(
                    recipes.filter { $0.sourceID != recipe.sourceID }
                )
            }
            return saved
        } catch is CancellationError {
            return nil
        } catch {
            saveFailures[recipe.sourceID] = RemoteFailureReport(error)
            return nil
        }
    }

}

struct DiscoverView: View {
    @State private var viewModel: DiscoverViewModel
    let saveRecipe: (SavedDiscoverRecipe) -> Void
    let openRecipe: (Recipe) -> Void
    /// Discover owns its view model, so the library above it cannot watch
    /// the feed. This reports the one thing it needs: the first page never
    /// arrived, and there is nothing cached to show instead.
    let onInitialLoadFailed: () -> Void
    @State private var initialLoadSettled = false

    init(
        service: any DiscoverServing,
        saveRecipe: @escaping (SavedDiscoverRecipe) -> Void,
        openRecipe: @escaping (Recipe) -> Void,
        onInitialLoadFailed: @escaping () -> Void = {}
    ) {
        _viewModel = State(
            initialValue: DiscoverViewModel(service: service)
        )
        self.saveRecipe = saveRecipe
        self.openRecipe = openRecipe
        self.onInitialLoadFailed = onInitialLoadFailed
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                loadingContent
            case let .loaded(recipes):
                loadedContent(recipes)
            case let .failed(report):
                failedContent(report)
            }
        }
        .background(LadleTheme.Surface.porcelain)
        .searchable(
            text: $viewModel.query,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search Discover"
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                sortMenu
            }
        }
        .task {
            if viewModel.state == .idle {
                await viewModel.load()
            }
        }
        .onChange(of: viewModel.state) { _, state in
            reportInitialLoad(state)
        }
        .accessibilityIdentifier("library.discover")
    }

    /// `load()` only writes `.failed` when it has nothing cached to keep, so
    /// that state alone means the first page failed — no need to inspect the
    /// state it came from, which a synchronous failure can skip past.
    private func reportInitialLoad(_ state: DiscoverViewModel.State) {
        guard !initialLoadSettled else { return }
        switch state {
        case .loaded:
            initialLoadSettled = true
        case .failed:
            initialLoadSettled = true
            onInitialLoadFailed()
        case .idle, .loading:
            break
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort Discover", selection: $viewModel.sort) {
                ForEach(DiscoverSort.allCases) { option in
                    Label(option.title, systemImage: option.systemImage)
                        .tag(option)
                }
            }
        } label: {
            Label(
                "Sort Discover",
                systemImage: "line.3.horizontal.decrease"
            )
        }
        .accessibilityIdentifier("discover.sort")
    }

    private var loadingContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { _ in
                    DiscoverLoadingRow()
                    Divider()
                        .overlay(LadleTheme.Label.primary.opacity(0.08))
                }
            }
            .padding(.horizontal, LadleTheme.Spacing.regular)
        }
        .scrollDisabled(true)
        .accessibilityLabel("Loading Discover")
    }

    private var emptyContent: some View {
        ContentUnavailableView(
            "Nothing to discover yet",
            systemImage: "sparkles",
            description: Text(
                "Public recipe saves will collect here as more cooks use Overeasy."
            )
        )
        .foregroundStyle(LadleTheme.Label.primary)
    }

    @ViewBuilder
    private func loadedContent(_ recipes: [DiscoverRecipe]) -> some View {
        Group {
            if recipes.isEmpty {
                // The server already applied the query, so an empty page
                // under an active search is a no-results state, not an
                // empty feed.
                if viewModel.query.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                    emptyContent
                } else {
                    ContentUnavailableView.search(text: viewModel.query)
                        .foregroundStyle(LadleTheme.Label.primary)
                        .accessibilityIdentifier("discover.no-results")
                }
            } else {
                recipeList(recipes)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            DiscoverRefreshBanner(
                state: viewModel.refreshState,
                retry: { Task { await viewModel.load() } }
            )
        }
    }

    private func failedContent(_ report: RemoteFailureReport) -> some View {
        ContentUnavailableView {
            Label(
                report.failure.title,
                systemImage: report.failure.systemImage
            )
        } description: {
            VStack(spacing: LadleTheme.Spacing.tight) {
                Text(report.failure.message)
                Text("Your saved recipes are still available.")
                if let retryAt = report.failure.retryAt {
                    Text("Try again after \(retryAt, style: .time).")
                }
            }
        } actions: {
            if report.failure.canRetry() {
                Button("Try again") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(LadleButtonStyle(role: .secondary))
            }
        }
        .foregroundStyle(LadleTheme.Label.primary)
        .accessibilityIdentifier("discover.initial-failure")
    }

    private func recipeList(_ recipes: [DiscoverRecipe]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved by cooks")
                        .ladleFont(.section)
                        .foregroundStyle(LadleTheme.Label.primary)
                    Text(viewModel.sort.caption)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.Label.secondary)
                }
                .padding(.vertical, LadleTheme.Spacing.medium)

                ForEach(recipes) { recipe in
                    DiscoverRecipeRow(
                        recipe: recipe,
                        sort: viewModel.sort,
                        isLoadingDetail: viewModel.isLoadingDetail(recipe),
                        isSaving: viewModel.isSaving(recipe),
                        isSaved: viewModel.isSaved(recipe),
                        openFailure: viewModel.detailFailure(for: recipe),
                        saveFailure: viewModel.saveFailure(for: recipe),
                        open: {
                            Task {
                                if let detail = await viewModel.detail(
                                    for: recipe
                                ) {
                                    openRecipe(detail)
                                }
                            }
                        },
                        save: {
                            Task {
                                if let saved = await viewModel.save(recipe) {
                                    saveRecipe(saved)
                                }
                            }
                        }
                    )
                    // Rows are lazy, so this fires as the reader approaches
                    // the end rather than for the whole list at once.
                    .onAppear {
                        guard viewModel.shouldLoadMore(after: recipe) else {
                            return
                        }
                        Task { await viewModel.loadMore() }
                    }
                    Divider()
                        .overlay(LadleTheme.Label.primary.opacity(0.08))
                }

                if viewModel.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .padding(.vertical, LadleTheme.Spacing.medium)
                    .accessibilityLabel("Loading more recipes")
                }
            }
            .padding(.horizontal, LadleTheme.Spacing.regular)
            .padding(.bottom, LadleTheme.Layout.scrollTail)
        }
        .scrollIndicators(.hidden)
        .refreshable { await viewModel.load() }
    }
}

private struct DiscoverRefreshBanner: View {
    let state: DiscoverViewModel.RefreshState
    let retry: () -> Void

    @ViewBuilder
    var body: some View {
        switch state {
        case .current:
            EmptyView()
        case .refreshing:
            content(systemImage: nil) {
                ProgressView().controlSize(.small)
                Text("Refreshing Discover…")
                    .ladleFont(.bodyStrong)
            }
        case let .failed(report):
            content(systemImage: report.failure.systemImage) {
                VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                    Text("Showing earlier Discover results")
                        .ladleFont(.bodyStrong)
                    Text(report.failure.message)
                        .ladleFont(.metadata)
                    if let retryAt = report.failure.retryAt {
                        Text("Try again after \(retryAt, style: .time).")
                            .ladleFont(.metadata)
                    }
                }
                Spacer(minLength: LadleTheme.Spacing.compact)
                if report.failure.canRetry() {
                    Button("Try Again", action: retry)
                        .ladleFont(.bodyStrong)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func content<Content: View>(
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
                    .accessibilityHidden(true)
            }
            content()
        }
        .foregroundStyle(LadleTheme.Label.primary)
        .padding(.horizontal, LadleTheme.Layout.screenMargin)
        .padding(.vertical, LadleTheme.Spacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LadleTheme.Surface.steel)
        .overlay(alignment: .bottom) {
            Divider().overlay(LadleTheme.Stroke.separator)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discover.refresh-status")
    }
}

private struct DiscoverRecipeRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.ladleAccent) private var accent

    let recipe: DiscoverRecipe
    let sort: DiscoverSort
    let isLoadingDetail: Bool
    let isSaving: Bool
    let isSaved: Bool
    let openFailure: RemoteFailureReport?
    let saveFailure: RemoteFailureReport?
    let open: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    Button(action: open) {
                        details
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingDetail)
                    saveButton
                }
            } else {
                HStack(alignment: .top, spacing: LadleTheme.Spacing.medium) {
                    Button(action: open) {
                        HStack(alignment: .top, spacing: LadleTheme.Spacing.medium) {
                            artwork
                            details
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingDetail)
                    saveButton
                }
            }
            if let openFailure {
                operationFailure("Open", report: openFailure)
            }
            if let saveFailure {
                operationFailure("Save", report: saveFailure)
            }
        }
        .padding(.vertical, LadleTheme.Spacing.medium)
        .contextMenu {
            Button("View Recipe", systemImage: "book.pages", action: open)
            if !isSaved {
                Button("Save Recipe", systemImage: "plus", action: save)
            }
        } preview: {
            DiscoverRecipeContextPreview(recipe: recipe)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open recipe", open)
        .accessibilityIdentifier(
            "discover.\(recipe.originalURL.absoluteString)"
        )
    }

    private func operationFailure(
        _ action: String,
        report: RemoteFailureReport
    ) -> some View {
        Label(
            "\(action): \(report.failure.title). \(report.failure.message)",
            systemImage: report.failure.systemImage
        )
        .ladleFont(.metadata)
        .foregroundStyle(accent.label)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var details: some View {
        HStack(alignment: .top, spacing: LadleTheme.Spacing.medium) {
            if dynamicTypeSize.isAccessibilitySize {
                artwork
            }
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                Text(recipe.creatorName ?? recipe.source.libraryTitle)
                    .ladleFont(.metadata)
                    .foregroundStyle(accent.label)
                    .lineLimit(1)
                Text(recipe.title)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .lineLimit(2)
                if !recipe.description.isEmpty {
                    Text(recipe.description)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.Label.secondary)
                        .lineLimit(2)
                }
                Text(saveCountText)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var artwork: some View {
        DiscoverArtwork(recipe: recipe)
        .frame(width: 96, height: 96)
        .clipShape(
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
        )
        .overlay {
            if isLoadingDetail {
                ZStack {
                    Rectangle().fill(.thinMaterial)
                    ProgressView()
                        .tint(accent.intent)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var saveButton: some View {
        Button(action: save) {
            Group {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LadleTheme.Label.onAccent)
                } else {
                    Label(
                        isSaved ? "Saved" : "Save",
                        systemImage: isSaved ? "checkmark" : "plus"
                    )
                }
            }
                .ladleFont(.metadata)
                .foregroundStyle(
                    isSaved ? LadleTheme.Label.primary : LadleTheme.Label.onAccent
                )
                .padding(.horizontal, LadleTheme.Spacing.medium)
                .frame(minHeight: LadleTheme.Control.hitTarget)
                .background(
                    isSaved ? LadleTheme.Intent.success : accent.intent,
                    in: Capsule()
                )
        }
        .buttonStyle(LadlePressButtonStyle())
        .disabled(isSaving || isSaved)
        .accessibilityLabel(
            isSaved ? "\(recipe.title) saved" : "Save \(recipe.title)"
        )
    }

    /// Under Most liked the row shows the number it is ranked by; showing
    /// saves there would leave the order looking arbitrary.
    private var saveCountText: String {
        if sort == .mostLiked, let likeCount = recipe.likeCount {
            return "\(likeCount.formatted(.number.notation(.compactName))) likes"
        }
        return recipe.savedCount == 1
            ? "Saved by 1 cook"
            : "Saved by \(recipe.savedCount) cooks"
    }
}

private struct DiscoverRecipeContextPreview: View {
    @Environment(\.ladleAccent) private var accent
    let recipe: DiscoverRecipe

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DiscoverArtwork(recipe: recipe)
            .frame(height: 210)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
            )

            Text(recipe.creatorName ?? recipe.source.libraryTitle)
                .ladleFont(.metadata)
                .foregroundStyle(accent.label)
            Text(recipe.title)
                .ladleFont(.section)
                .foregroundStyle(LadleTheme.Label.primary)
                .lineLimit(2)
            if !recipe.description.isEmpty {
                Text(recipe.description)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.secondary)
                    .lineLimit(3)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(LadleTheme.Surface.porcelain)
    }
}

private struct DiscoverArtwork: View {
    let recipe: DiscoverRecipe

    var body: some View {
        RecipeArtworkView(
            owner: .discoverSource(id: recipe.sourceID),
            image: image
        )
    }

    /// A served Discover row carries a remote thumbnail URL. Demo rows carry
    /// none — fixture artwork is a bundled asset — so they fall back to the
    /// fixture, which is why the demo feed showed placeholder pans.
    private var image: RecipeImage? {
        if let imageURL = recipe.imageURL {
            return RecipeImage(id: recipe.sourceID, remoteURL: imageURL)
        }
        return PreviewFixtures.discoverArtwork(sourceID: recipe.sourceID)
    }
}

private struct DiscoverLoadingRow: View {
    var body: some View {
        HStack(spacing: LadleTheme.Spacing.medium) {
            RoundedRectangle(cornerRadius: LadleTheme.Corner.control)
                .fill(LadleTheme.Surface.raised)
                .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.compact) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LadleTheme.Surface.steel)
                    .frame(width: 90, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LadleTheme.Surface.raised)
                    .frame(height: 18)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LadleTheme.Surface.raised)
                    .frame(width: 150, height: 12)
            }
        }
        .padding(.vertical, LadleTheme.Spacing.medium)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}
