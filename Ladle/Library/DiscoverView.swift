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

    /// Page 1 as it now stands, fetched without disturbing the feed and held
    /// until the cook asks for it. Nothing about it is on screen except the
    /// pill that offers it.
    struct PendingPage: Equatable {
        let recipes: [DiscoverRecipe]
        let nextCursor: Int
        let hasMore: Bool
        /// The pin it was ranked under. Applying the page adopts this as the
        /// paging session, so the pages walked after it line up with it.
        let pin: Date
    }

    /// Discover spends at most one quiet request a minute, however often the
    /// cook travels back to the top.
    static let quietRefreshInterval: TimeInterval = 60

    private let service: any DiscoverServing
    private let now: @MainActor () -> Date
    private let removesSavedRecipeImmediately: Bool
    private let loadsShelves: Bool
    private let recordsSeenSources: Bool
    /// The last time a fetch replaced a feed the cook was already reading —
    /// a pull, a quiet refresh, or taking one. The first load is not one of
    /// those: it is the feed, not a refresh of it.
    private var lastRefreshedAt = Date.distantPast
    private var isRefreshingQuietly = false
    private(set) var pending: PendingPage?
    /// The moment this paging session began, sent with every page of it. The
    /// server demotes only what was seen *before* it, so the rows this walk
    /// records cannot re-rank the pages it has not fetched yet.
    private var sessionStartedAt: Date?
    /// The rails as last loaded. `visibleShelves` is what the screen draws.
    private(set) var shelves: [DiscoverShelf] = []
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
        removesSavedRecipeImmediately: Bool = true,
        loadsShelves: Bool = true,
        recordsSeenSources: Bool = true,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.service = service
        self.removesSavedRecipeImmediately = removesSavedRecipeImmediately
        self.loadsShelves = loadsShelves
        self.recordsSeenSources = recordsSeenSources
        self.now = now
    }

    /// The server already applied the query, so this is also what makes an
    /// empty page a no-results state rather than an empty feed.
    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The rails the screen draws. Hidden entirely under a search, because
    /// search replaces the feed and a rail of unsearched rows beside the
    /// results would look like results. A rail with fewer than three cards
    /// is dropped: it reads as a mistake next to the list below it.
    var visibleShelves: [DiscoverShelf] {
        guard !isSearching else { return [] }
        return shelves.filter {
            $0.recipes.count >= DiscoverShelf.minimumRecipes
        }
    }

    private func criteriaChanged() {
        generation += 1
        nextCursor = 0
        hasMore = false
        // A held page belongs to the query and sort it was fetched under.
        pending = nil
        state = .loading
    }

    /// Loads the first page for the current query and sort, replacing
    /// whatever is on screen. Also the refresh path.
    ///
    /// Every call starts a new paging session, which is the point: pulling to
    /// refresh, changing the sort or coming back to a feed the cook has
    /// already read is exactly when they are asking for different rows.
    func load() async {
        guard refreshState != .refreshing else { return }
        // Whatever was waiting was ranked against the session this replaces.
        pending = nil
        sessionStartedAt = recordsSeenSources ? now() : nil
        let token = generation
        let cachedRecipes: [DiscoverRecipe]?
        if case let .loaded(recipes) = state, !recipes.isEmpty {
            cachedRecipes = recipes
            // A pull over a feed already on screen is a refresh; a cold first
            // load is not, so returning to the top of a freshly opened feed
            // is still allowed to look for something new.
            lastRefreshedAt = now()
            refreshState = .refreshing
        } else {
            cachedRecipes = nil
            state = .loading
        }
        // The rails go out beside page 1 rather than after it, and their
        // result is taken whatever the page does. A shelf never throws — a
        // failed rail is simply absent — so the feed cannot fail because a
        // rail did, and a failed feed does not cost the reader the rails.
        async let loadedShelves = fetchShelves()
        let pageResult: Result<DiscoverPage, any Error>
        do {
            pageResult = .success(
                try await service.fetchDiscoverPage(
                    cursor: 0,
                    query: query,
                    sort: sort,
                    seenBefore: sessionStartedAt
                )
            )
        } catch {
            pageResult = .failure(error)
        }
        let shelves = await loadedShelves
        guard token == generation else { return }
        self.shelves = shelves
        switch pageResult {
        case let .success(page):
            savedSourceIDs = Set(
                page.recipes.lazy.compactMap { recipe in
                    recipe.savedRecipeID == nil ? nil : recipe.sourceID
                }
            )
            nextCursor = page.nextCursor
            hasMore = page.hasMore
            state = .loaded(page.recipes.filter { $0.savedRecipeID == nil })
            refreshState = .current
        case .failure(is CancellationError):
            if let cachedRecipes {
                state = .loaded(cachedRecipes)
                refreshState = .current
            } else {
                state = .idle
            }
        case let .failure(error):
            let report = RemoteFailureReport(error)
            if let cachedRecipes {
                state = .loaded(cachedRecipes)
                refreshState = .failed(report)
            } else {
                state = .failed(report)
            }
        }
    }

    /// Fetches page 1 behind the reader's back and holds it. Nothing on
    /// screen moves: the refresh banner stays out of this, and a page that
    /// turns out to match what is already there is dropped without a word.
    ///
    /// Scrolling back to the top is how someone returns to a row they meant
    /// to keep, so the feed cannot be replaced at that moment. It can only
    /// be offered.
    func refreshQuietly() async {
        let startedAt = now()
        guard recordsSeenSources, !isSearching, pending == nil,
              !isRefreshingQuietly, refreshState != .refreshing,
              case let .loaded(onScreen) = state, !onScreen.isEmpty,
              startedAt.timeIntervalSince(lastRefreshedAt)
                  >= Self.quietRefreshInterval
        else { return }
        lastRefreshedAt = startedAt
        isRefreshingQuietly = true
        defer { isRefreshingQuietly = false }
        let token = generation
        // The session this page would be an answer to. A pull that lands
        // while the quiet fetch is out starts a new one without touching
        // the generation, and the older page must not surface behind it.
        let session = sessionStartedAt
        // A fresh pin, or the server ranks this exactly as the session the
        // cook is already reading and hands back the same rows. Recording
        // off: this page may never be looked at, and marking it seen would
        // bury rows nobody was shown.
        guard let page = try? await service.fetchDiscoverPage(
            cursor: 0,
            query: query,
            sort: sort,
            seenBefore: startedAt,
            recordsImpressions: false
        ) else { return }
        // Nobody asked for this, so nobody is told it failed.
        guard token == generation, sessionStartedAt == session,
              case let .loaded(current) = state
        else { return }
        let recipes = page.recipes.filter {
            $0.savedRecipeID == nil && !savedSourceIDs.contains($0.sourceID)
        }
        // Page 1 against the first page's worth of what is on screen: after
        // paging the list is longer than a page, and comparing the whole of
        // it would call every feed new.
        guard !recipes.isEmpty,
              recipes.map(\.sourceID)
                  != current.prefix(recipes.count).map(\.sourceID)
        else { return }
        pending = PendingPage(
            recipes: recipes,
            nextCursor: page.nextCursor,
            hasMore: page.hasMore,
            pin: startedAt
        )
    }

    /// Swaps the held page in. The rows are already in hand, so the list
    /// moves at once rather than behind a spinner; the same page is then
    /// re-fetched under the same pin with recording on, because the quiet
    /// fetch deliberately recorded nothing. What the cook is shown has to be
    /// what the server marked as read, so the recorded page wins if the two
    /// ever disagree.
    func applyPending() async {
        guard let applied = pending else { return }
        pending = nil
        // Anything still in flight was ranked against the session this
        // replaces.
        generation += 1
        let token = generation
        sessionStartedAt = applied.pin
        lastRefreshedAt = now()
        refreshState = .current
        nextCursor = applied.nextCursor
        hasMore = applied.hasMore
        state = .loaded(
            applied.recipes.filter { !savedSourceIDs.contains($0.sourceID) }
        )
        // The rails are the same feed under another order, so they turn over
        // with it rather than keeping cards the list no longer has.
        async let loadedShelves = fetchShelves()
        let recorded = try? await service.fetchDiscoverPage(
            cursor: 0,
            query: query,
            sort: sort,
            seenBefore: applied.pin,
            recordsImpressions: true
        )
        let shelves = await loadedShelves
        guard token == generation else { return }
        self.shelves = shelves
        // A failed recording leaves the rows the cook took: they are the
        // right rows, they simply are not written down yet.
        guard let recorded else { return }
        nextCursor = recorded.nextCursor
        hasMore = recorded.hasMore
        state = .loaded(
            recorded.recipes.filter {
                $0.savedRecipeID == nil && !savedSourceIDs.contains($0.sourceID)
            }
        )
    }

    /// Both rails, in the order they are drawn. Two `async let`s rather than
    /// a loop over the cases: the requests are independent and a rail should
    /// not wait on the one above it.
    private func fetchShelves() async -> [DiscoverShelf] {
        guard loadsShelves, !isSearching else { return [] }
        async let arrivals = fetchShelf(.newToOvereasy)
        async let quick = fetchShelf(.quickDinners)
        return await [arrivals, quick].compactMap { $0 }
    }

    /// Nil when the rail could not be filled. A rail is decoration on top of
    /// the feed, so its failure is silent — there is no banner, no retry and
    /// nothing for the reader to act on.
    ///
    /// No `seenBefore`: "New to Overeasy" that hid what is new because the
    /// cook glanced at it, or a rail reordered by the list underneath it,
    /// would stop meaning what its title says.
    private func fetchShelf(_ id: DiscoverShelf.ID) async -> DiscoverShelf? {
        guard let page = try? await service.fetchDiscoverPage(
            cursor: 0,
            query: "",
            sort: id.sort,
            maxTotalMinutes: id.maxTotalMinutes,
            limit: DiscoverPaging.shelfSize,
            seenBefore: nil,
            recordsImpressions: false
        ) else { return nil }
        return DiscoverShelf(
            id: id,
            recipes: page.recipes.filter { $0.savedRecipeID == nil }
        )
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
                sort: sort,
                // The session's own timestamp, not this moment: a fresh one
                // here would re-rank against the rows page 1 just recorded
                // and hand the cook repeats.
                seenBefore: sessionStartedAt
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
            if removesSavedRecipeImmediately {
                if case let .loaded(recipes) = state {
                    state = .loaded(
                        recipes.filter { $0.sourceID != recipe.sourceID }
                    )
                }
                // A rail is the same feed, so a source saved from its context
                // menu has to leave the rail as well as the list. Dropping to
                // fewer than three cards hides the rail, which is the right
                // outcome: it is no longer a shelf.
                shelves = shelves.map { shelf in
                    DiscoverShelf(
                        id: shelf.id,
                        recipes: shelf.recipes.filter {
                            $0.sourceID != recipe.sourceID
                        }
                    )
                }
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
    /// Set when the cook scrolls more than a screen down, cleared when the
    /// return to the top is spent. Reaching the top only asks for a fresh
    /// page if they had genuinely left it — a bounce is not a journey.
    @State private var hasScrolledAScreenAway = false
    /// Bumped to send the list back to the top; the scroll proxy that can do
    /// it lives inside the feed, and the pill that asks for it does not.
    @State private var scrollToTopRequests = 0

    private static let topAnchor = "discover.top"

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
                if !viewModel.isSearching {
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
            // One bar, never two. A page waiting to be taken supersedes a
            // banner about the page that failed to arrive: it is the newer
            // news, and stacking the two would read as a pile-up.
            if viewModel.pending == nil {
                DiscoverRefreshBanner(
                    state: viewModel.refreshState,
                    retry: { Task { await viewModel.load() } }
                )
            } else {
                DiscoverNewRecipesPill(take: takePendingPage)
            }
        }
    }

    /// The pill's whole job. The rows are already in hand, so the swap is
    /// immediate; the scroll is what makes it a beginning rather than a
    /// reshuffle around wherever the cook happened to be.
    private func takePendingPage() {
        // The scroll below crosses the top edge on its way in. Without this
        // the arrival would arm another quiet fetch at once.
        hasScrolledAScreenAway = false
        scrollToTopRequests += 1
        Task { await viewModel.applyPending() }
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

    /// Opening and saving are the same two actions from a rail card as from
    /// a list row, so both surfaces call these rather than each closing over
    /// their own copy of the work.
    private func open(_ recipe: DiscoverRecipe) {
        Task {
            if let detail = await viewModel.detail(for: recipe) {
                openRecipe(detail)
            }
        }
    }

    private func save(_ recipe: DiscoverRecipe) {
        Task {
            if let saved = await viewModel.save(recipe) {
                saveRecipe(saved)
            }
        }
    }

    private func recipeList(_ recipes: [DiscoverRecipe]) -> some View {
        ScrollViewReader { scroll in
            feed(recipes)
                .onChange(of: scrollToTopRequests) {
                    withAnimation {
                        scroll.scrollTo(Self.topAnchor, anchor: .top)
                    }
                }
        }
    }

    private func feed(_ recipes: [DiscoverRecipe]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 0)
                    .id(Self.topAnchor)

                ForEach(viewModel.visibleShelves) { shelf in
                    DiscoverShelfView(
                        shelf: shelf,
                        isLoadingDetail: { viewModel.isLoadingDetail($0) },
                        isSaved: { viewModel.isSaved($0) },
                        open: open,
                        save: save
                    )
                    .padding(.top, LadleTheme.Spacing.medium)
                }

                VStack(alignment: .leading, spacing: 4) {
                    // The rails carry the turnover; this is the whole
                    // corpus, which is what the reader scrolls into.
                    Text("All recipes")
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
                        open: { open(recipe) },
                        save: { save(recipe) }
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
        .onScrollGeometryChange(for: DiscoverScrollSignal.self) {
            DiscoverScrollSignal($0)
        } action: { previous, current in
            reachedTop(from: previous, to: current)
        }
        .refreshable { await viewModel.load() }
    }

    /// The false→true edge of arriving at the top, and only if the cook had
    /// left it. Reaching the top is the one moment Discover has a reason to
    /// look for something new: the reader is between rows rather than in the
    /// middle of one.
    private func reachedTop(
        from previous: DiscoverScrollSignal,
        to current: DiscoverScrollSignal
    ) {
        if current.isAScreenDown {
            hasScrolledAScreenAway = true
        }
        guard !previous.isAtTop, current.isAtTop, hasScrolledAScreenAway
        else { return }
        // Spent whether or not the fetch happens, so a cook bouncing on the
        // top edge cannot keep asking.
        hasScrolledAScreenAway = false
        Task { await viewModel.refreshQuietly() }
    }
}

/// Two coarse facts rather than the offset itself, so the observation fires
/// when the scroll crosses a threshold instead of on every frame.
private struct DiscoverScrollSignal: Equatable {
    var isAtTop: Bool
    var isAScreenDown: Bool

    init(_ geometry: ScrollGeometry) {
        // Measured from the top of the content, not from `contentOffset.y`
        // alone: under the large title and the search drawer the resting
        // offset at the top is minus the inset, so the raw value stays at or
        // below zero well into the first screenful.
        let distance = geometry.contentOffset.y + geometry.contentInsets.top
        isAtTop = distance <= 0
        // One viewport, so a row or two of travel never counts as leaving.
        isAScreenDown = distance > geometry.containerSize.height
    }
}

/// The other thing that can sit under the navigation bar. Deliberately the
/// same strip of steel as the refresh banner: a second announcement language
/// on one screen would make the feed look like it is talking to itself.
private struct DiscoverNewRecipesPill: View {
    let take: () -> Void

    var body: some View {
        Button(action: take) {
            DiscoverTopBar(
                systemImage: "arrow.up.circle.fill",
                identifier: "discover.new-recipes"
            ) {
                Text("New recipes")
                    .ladleFont(.bodyStrong)
                Spacer(minLength: LadleTheme.Spacing.compact)
            }
        }
        .buttonStyle(.plain)
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
            DiscoverTopBar(systemImage: nil, identifier: Self.identifier) {
                ProgressView().controlSize(.small)
                Text("Refreshing Discover…")
                    .ladleFont(.bodyStrong)
            }
        case let .failed(report):
            DiscoverTopBar(
                systemImage: report.failure.systemImage,
                identifier: Self.identifier
            ) {
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

    private static let identifier = "discover.refresh-status"
}

/// The one bar Discover puts under the navigation bar, whatever it has to
/// say. Shared so the refresh banner and the "New recipes" pill cannot drift
/// into two different pieces of furniture.
private struct DiscoverTopBar<Content: View>: View {
    let systemImage: String?
    let identifier: String
    @ViewBuilder let content: () -> Content

    var body: some View {
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
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

private extension View {
    /// One Discover long-press, wherever the recipe is drawn. A rail card
    /// and a list row have to offer the same actions and the same preview,
    /// or the gesture means two different things on one screen.
    func discoverContextMenu(
        recipe: DiscoverRecipe,
        isSaved: Bool,
        open: @escaping () -> Void,
        save: @escaping () -> Void
    ) -> some View {
        contextMenu {
            Button("View Recipe", systemImage: "book.pages", action: open)
            if !isSaved {
                Button("Save Recipe", systemImage: "plus", action: save)
            }
        } preview: {
            DiscoverRecipeContextPreview(recipe: recipe)
        }
    }
}

/// One rail: a title, a caption, and a horizontally scrolling row of cards
/// that bleed past the screen margin so the next card is visibly cut off
/// rather than sitting flush with the text above it.
private struct DiscoverShelfView: View {
    let shelf: DiscoverShelf
    let isLoadingDetail: (DiscoverRecipe) -> Bool
    let isSaved: (DiscoverRecipe) -> Bool
    let open: (DiscoverRecipe) -> Void
    let save: (DiscoverRecipe) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shelf.title)
                    .ladleFont(.section)
                    .foregroundStyle(LadleTheme.Label.primary)
                Text(shelf.caption)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.secondary)
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: LadleTheme.Spacing.medium) {
                    ForEach(shelf.recipes) { recipe in
                        DiscoverShelfCard(
                            shelf: shelf.id,
                            recipe: recipe,
                            isLoadingDetail: isLoadingDetail(recipe),
                            isSaved: isSaved(recipe),
                            open: { open(recipe) },
                            save: { save(recipe) }
                        )
                    }
                }
                .scrollTargetLayout()
                // The rail is drawn inside the list's own horizontal margin,
                // so the cards are inset back to it and the scroll view is
                // widened past it — that is what lets a card bleed off-screen.
                .padding(.horizontal, LadleTheme.Layout.screenMargin)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .padding(.horizontal, -LadleTheme.Layout.screenMargin)
        }
        .padding(.bottom, LadleTheme.Layout.sectionGap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(shelf.title)
    }
}

private struct DiscoverShelfCard: View {
    @Environment(\.ladleAccent) private var accent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Points from the prototype linked on #29. LadleTheme has no card-size
    /// token and one component is not enough to name a step, so they live
    /// here — scaled, so the card grows with the reader's type size instead
    /// of squeezing four lines into two.
    @ScaledMetric(relativeTo: .body) private var scaledWidth: CGFloat = 152
    @ScaledMetric(relativeTo: .body) private var scaledArtworkHeight: CGFloat = 114

    /// Uncapped, 152 points scales past the width of the phone somewhere
    /// around AX4 — a "rail" whose one card is wider than the viewport it
    /// scrolls in. This stops at a width that still leaves the next card
    /// peeking on the narrowest iPhone; the title takes a third line
    /// instead, which is what a reader at that size actually needs. The row
    /// restacks vertically at these sizes; a horizontal rail cannot.
    private static let maximumWidth: CGFloat = 280

    private var width: CGFloat { min(scaledWidth, Self.maximumWidth) }

    private var artworkHeight: CGFloat {
        min(scaledArtworkHeight, Self.maximumWidth * 114 / 152)
    }

    private var titleLines: Int { dynamicTypeSize.isAccessibilitySize ? 3 : 2 }

    let shelf: DiscoverShelf.ID
    let recipe: DiscoverRecipe
    let isLoadingDetail: Bool
    let isSaved: Bool
    let open: () -> Void
    let save: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.compact) {
                artwork
                Text(recipe.title)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .lineLimit(titleLines, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(recipe.creatorName ?? recipe.source.libraryTitle)
                    .ladleFont(.metadata)
                    .foregroundStyle(accent.label)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(LadlePressButtonStyle())
        .disabled(isLoadingDetail)
        // No Save on the card: the list below carries it, and a 44-point
        // capsule on a 152-point card would be the loudest thing in the rail.
        .discoverContextMenu(
            recipe: recipe,
            isSaved: isSaved,
            open: open,
            save: save
        )
        // One target rather than three texts, so a card is a single VoiceOver
        // stop and its title does not appear a second time in the hierarchy.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(recipe.title), \(recipe.creatorName ?? recipe.source.libraryTitle)"
        )
        .accessibilityIdentifier(
            "discover.card.\(shelf.rawValue).\(recipe.originalURL.absoluteString)"
        )
    }

    private var artwork: some View {
        DiscoverArtwork(recipe: recipe)
            .frame(width: width, height: artworkHeight)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.thumbnail,
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
        .discoverContextMenu(
            recipe: recipe,
            isSaved: isSaved,
            open: open,
            save: save
        )
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
