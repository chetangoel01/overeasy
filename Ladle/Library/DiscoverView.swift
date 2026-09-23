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
    private let shuffleShelfIDs: ([DiscoverShelf.ID]) -> [DiscoverShelf.ID]
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
    /// The order the shelves are placed in: the first two that can be drawn
    /// lead, and the rest go into the list. Drawn once and only ever added
    /// to, so nothing moves under the cook until a relaunch — the rule Watch
    /// follows for its videos. An id outlives its shelf, so one that a filter
    /// took away comes back where it was.
    private var shelfOrder: [DiscoverShelf.ID] = []
    /// The shelves as last loaded. `visibleShelves` is what the screen draws.
    private(set) var shelves: [DiscoverShelf] = [] {
        didSet {
            let arrivals = shelves.map(\.id)
                .filter { !shelfOrder.contains($0) }
            shelfOrder += shuffleShelfIDs(arrivals)
        }
    }
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

    /// The shared tag filter, mirrored from `RecipeFilterStore`. Discover
    /// cannot narrow a page it has already fetched — the server returns
    /// whole pages and thinning one would break paging — so a change here is
    /// a new first page, exactly like changing the sort.
    var filter: RecipeFilter = .none {
        didSet {
            guard filter != oldValue else { return }
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
        filter: RecipeFilter = .none,
        removesSavedRecipeImmediately: Bool = true,
        loadsShelves: Bool = true,
        recordsSeenSources: Bool = true,
        now: @escaping @MainActor () -> Date = { Date() },
        shuffleShelfIDs:
            @escaping ([DiscoverShelf.ID]) -> [DiscoverShelf.ID] = {
                $0.shuffled()
            }
    ) {
        self.filter = filter
        self.service = service
        self.removesSavedRecipeImmediately = removesSavedRecipeImmediately
        self.loadsShelves = loadsShelves
        self.recordsSeenSources = recordsSeenSources
        self.now = now
        self.shuffleShelfIDs = shuffleShelfIDs
    }

    /// The server already applied the query, so this is also what makes an
    /// empty page a no-results state rather than an empty feed.
    var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The shelves the screen draws, in the order it places them. Hidden
    /// entirely under a search, because search replaces the feed and a shelf
    /// of unsearched rows beside the results would look like results. A shelf
    /// with fewer than three cards is dropped: it reads as a mistake next to
    /// the list around it.
    ///
    /// A keyword the cook is already filtering on is dropped too. Its shelf
    /// would be the first few rows of the list underneath it, which is what
    /// "See all" just took them to — the same reason search hides the lot.
    var visibleShelves: [DiscoverShelf] {
        guard !isSearching else { return [] }
        return shelfOrder.compactMap { id in
            shelves.first { $0.id == id }
        }.filter { shelf in
            guard shelf.recipes.count >= DiscoverShelf.minimumRecipes else {
                return false
            }
            guard let keyword = shelf.keyword else { return true }
            return !filter.keywords.contains(keyword)
        }
    }

    /// The two above "All recipes". Whatever `visibleShelves` drops — a
    /// short shelf, a filtered keyword, a rail that never loaded — the next
    /// in the order moves up, so two lead whenever two can.
    var leadShelves: [DiscoverShelf] {
        Array(visibleShelves.prefix(DiscoverShelf.leadCount))
    }

    /// Every other shelf, which the list takes in one at a time.
    var feedShelves: [DiscoverShelf] {
        Array(visibleShelves.dropFirst(DiscoverShelf.leadCount))
    }

    /// The shelves drawn under the row at `index` of the `rows` on screen:
    /// one at most, except under the last row of a list that has ended.
    func feedShelves(afterRow index: Int, of rows: Int) -> [DiscoverShelf] {
        feedShelves.enumerated().filter { position, _ in
            DiscoverShelf.feedSlot(position, rows: rows, hasMore: hasMore)
                == index
        }.map(\.element)
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
                    filter: filter,
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
    /// screen moves: a failure here draws no banner, and a page that turns
    /// out to match what is already there is dropped without a word.
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
            filter: filter,
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
            filter: filter,
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

    /// Every shelf: the two curated rails, then the keyword shelves in the
    /// order the server composed them. Independent `async let`s rather than
    /// a loop, because none of them should wait on the one above it — and
    /// the keyword shelves arrive as one request whatever their number,
    /// since the server decides how many there are.
    ///
    /// This is the order they are fetched in, not the order they are drawn
    /// in. `shelfOrder` decides that, and only a demo run, which shuffles
    /// nothing, draws them as they come.
    private func fetchShelves() async -> [DiscoverShelf] {
        guard loadsShelves, !isSearching else { return [] }
        async let arrivals = fetchShelf(.newToOvereasy)
        async let quick = fetchShelf(.quickDinners)
        async let keywords = fetchKeywordShelves()
        return await [arrivals, quick].compactMap { $0 } + keywords
    }

    /// Empty when they could not be fetched. Silent for the same reason a
    /// rail is: a shelf is decoration on top of the feed, and there is
    /// nothing here for the reader to retry.
    private func fetchKeywordShelves() async -> [DiscoverShelf] {
        let shelves = try? await service.fetchKeywordShelves(
            filter: filter,
            limit: DiscoverPaging.shelfSize
        )
        return (shelves ?? []).map { shelf in
            var shelf = shelf
            shelf.recipes = shelf.recipes.filter { $0.savedRecipeID == nil }
            return shelf
        }
    }

    /// Nil when the rail could not be filled. A rail is decoration on top of
    /// the feed, so its failure is silent — there is no banner, no retry and
    /// nothing for the reader to act on.
    ///
    /// No `seenBefore`: "New to Overeasy" that hid what is new because the
    /// cook glanced at it, or a rail reordered by the list underneath it,
    /// would stop meaning what its title says.
    private func fetchShelf(_ rail: DiscoverRail) async -> DiscoverShelf? {
        guard let page = try? await service.fetchDiscoverPage(
            cursor: 0,
            query: "",
            sort: rail.sort,
            // A rail is the same feed under another order, so it answers
            // the same filter. A shelf of dishes the cook's diet rules out
            // would be an advertisement for food they cannot eat.
            filter: filter,
            maxTotalMinutes: rail.maxTotalMinutes,
            limit: DiscoverPaging.shelfSize,
            seenBefore: nil,
            recordsImpressions: false
        ) else { return nil }
        return DiscoverShelf(
            rail: rail,
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
                filter: filter,
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
                // A shelf is the same feed, so a source saved from its
                // context menu has to leave the shelf as well as the list.
                // Dropping to fewer than three cards hides the shelf, which
                // is the right outcome: it is no longer one, and the next in
                // the order takes its place.
                shelves = shelves.map { shelf in
                    var shelf = shelf
                    shelf.recipes.removeAll {
                        $0.sourceID == recipe.sourceID
                    }
                    return shelf
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

/// The recipe page's handle on the Discover card's save path. The page is
/// pushed by the library, which cannot see the feed's view model, so the feed
/// hands this up with the recipe: the same `save`, the same optimistic
/// bookkeeping, the same failure report — plus the one thing the page adds,
/// which is that a landed save turns the preview into the saved copy the cook
/// goes on reading.
@MainActor
@Observable
final class DiscoverSaveModel {
    /// The feed row this page was opened from. A Discover preview's recipe id
    /// is this `sourceID`, which is how the library matches the two up.
    let source: DiscoverRecipe

    private let viewModel: DiscoverViewModel
    private let didSave: (SavedDiscoverRecipe) -> Void

    /// `.discover` until the save lands. The page follows this rather than the
    /// access it was pushed with.
    private(set) var access: LibraryRecipeAccess = .discover

    init(
        source: DiscoverRecipe,
        viewModel: DiscoverViewModel,
        didSave: @escaping (SavedDiscoverRecipe) -> Void
    ) {
        self.source = source
        self.viewModel = viewModel
        self.didSave = didSave
    }

    var isSaving: Bool { viewModel.isSaving(source) }

    /// Watch leaves a saved page in its feed, so a page can open for a source
    /// that is already saved. The shared path drops a second save for one, so
    /// the control says Saved rather than offering a request that goes
    /// nowhere.
    var isSaved: Bool { access == .saved || viewModel.isSaved(source) }

    var failure: RemoteFailureReport? { viewModel.saveFailure(for: source) }

    @discardableResult
    func save() async -> SavedDiscoverRecipe? {
        guard let saved = await viewModel.save(source) else { return nil }
        // Stored before the flip: the library has to be holding the recipe by
        // the time the favourite and options controls appear for it.
        didSave(saved)
        access = .saved
        return saved
    }
}

struct DiscoverView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: DiscoverViewModel
    /// The state; the view model holds only a mirror of it, so the feed can
    /// be tested without a preference store behind it.
    @Bindable var filters: RecipeFilterStore
    let saveRecipe: (SavedDiscoverRecipe) -> Void
    /// The detail page goes up with the save path behind it, because the page
    /// is pushed by the library and Save there has to be this feed's Save —
    /// and with the card it was opened from, which it zooms out of.
    let openRecipe: (Recipe, DiscoverSaveModel, RecipeZoomID) -> Void
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
        filters: RecipeFilterStore,
        saveRecipe: @escaping (SavedDiscoverRecipe) -> Void,
        openRecipe: @escaping (Recipe, DiscoverSaveModel, RecipeZoomID) -> Void,
        onInitialLoadFailed: @escaping () -> Void = {},
        shuffleShelfIDs: @escaping ([DiscoverShelf.ID]) -> [DiscoverShelf.ID]
    ) {
        // Seeded rather than assigned after the fact: a diet held from the
        // last launch has to be part of the first request, not a reload of
        // a page that was already wrong.
        _viewModel = State(
            initialValue: DiscoverViewModel(
                service: service,
                filter: filters.filter,
                shuffleShelfIDs: shuffleShelfIDs
            )
        )
        self.filters = filters
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortMenu
                filterMenu
            }
        }
        .task {
            if viewModel.state == .idle {
                await viewModel.load()
            }
        }
        // The state lives in the store and the feed follows it, so a diet
        // chosen on Recipes is already applied when Discover comes forward.
        .onChange(of: filters.filter) { _, filter in
            viewModel.filter = filter
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
            // Not the filter glyph it used to borrow: there is a real
            // filter control beside it now, and two lots of the same icon
            // would say the two buttons did the same thing.
            Label("Sort Discover", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("discover.sort")
    }

    private var filterMenu: some View {
        RecipeFilterMenu(filters: filters) {
            Label(
                "Filters",
                systemImage: filters.filter.isEmpty
                    ? "line.3.horizontal.decrease"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .accessibilityIdentifier("discover.filter")
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

    private var filteredOutContent: some View {
        ContentUnavailableView {
            SwiftUI.Label("No matching recipes", systemImage: "line.3.horizontal.decrease")
        } description: {
            Text("Nothing in Discover matches \(filters.filter.summary).")
        } actions: {
            Button("Clear filters") {
                filters.clearFilters()
            }
            .buttonStyle(LadleButtonStyle(role: .secondary))
        }
        .foregroundStyle(LadleTheme.Label.primary)
        .accessibilityIdentifier("discover.no-filter-results")
    }

    @ViewBuilder
    private func loadedContent(_ recipes: [DiscoverRecipe]) -> some View {
        Group {
            if recipes.isEmpty {
                // The server already applied both, so an empty page under a
                // search or a filter is a no-results state rather than an
                // empty feed — and it has to say which of the two emptied
                // it, because a diet held from the last launch is invisible
                // otherwise.
                if !filters.filter.isEmpty {
                    filteredOutContent
                } else if !viewModel.isSearching {
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
            RecipeFilterChipsRow(
                chips: LibraryFilterChip.chips(for: filters)
            )
            .padding(.horizontal, LadleTheme.Spacing.regular)
            .padding(.bottom, LadleTheme.Spacing.tight)
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
    /// their own copy of the work. A rail card names its shelf, so the page
    /// zooms out of that card and not the same recipe's row in the list; a
    /// list row names none.
    private func open(
        _ recipe: DiscoverRecipe,
        shelf: DiscoverShelf.ID? = nil
    ) {
        Task {
            if let detail = await viewModel.detail(for: recipe) {
                openRecipe(
                    detail,
                    DiscoverSaveModel(
                        source: recipe,
                        viewModel: viewModel,
                        didSave: saveRecipe
                    ),
                    RecipeZoomID(recipe.sourceID, shelf: shelf)
                )
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

    /// A shelf is the same view above "All recipes" and inside it.
    private func shelfView(_ shelf: DiscoverShelf) -> some View {
        DiscoverShelfView(
            shelf: shelf,
            isLoadingDetail: { viewModel.isLoadingDetail($0) },
            isSaved: { viewModel.isSaved($0) },
            open: { open($0, shelf: shelf.id) },
            save: save,
            showAll: { filters.showAll(keyword: $0) }
        )
    }

    private func recipeList(_ recipes: [DiscoverRecipe]) -> some View {
        ScrollViewReader { scroll in
            feed(recipes)
                .onChange(of: scrollToTopRequests) {
                    withAnimation(reduceMotion ? nil : .default) {
                        scroll.scrollTo(Self.topAnchor, anchor: .top)
                    }
                }
        }
    }

    private func feed(_ recipes: [DiscoverRecipe]) -> some View {
        ScrollView {
            // Only the rows are lazy. Which shelves lead can change while
            // the cook is far down the list — a save can take one under the
            // floor — and a lazy stack places what it has not measured yet
            // by estimate, which left the first shelf sitting high on the
            // way back up. Two shelves cost nothing to keep alive.
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 0)
                    .id(Self.topAnchor)

                ForEach(viewModel.leadShelves) { shelf in
                    shelfView(shelf)
                        .padding(.top, LadleTheme.Spacing.medium)
                }

                VStack(alignment: .leading, spacing: 4) {
                    // The shelves carry the turnover; this is the whole
                    // corpus, which is what the reader scrolls into.
                    Text("All recipes")
                        .ladleFont(.section)
                        .foregroundStyle(LadleTheme.Label.primary)
                    Text(viewModel.sort.caption)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.Label.secondary)
                }
                .padding(.vertical, LadleTheme.Spacing.medium)

                rows(recipes)
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

    private func rows(_ recipes: [DiscoverRecipe]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(
                Array(recipes.enumerated()),
                id: \.element.id
            ) { index, recipe in
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
                ForEach(
                    viewModel.feedShelves(
                        afterRow: index,
                        of: recipes.count
                    )
                ) { shelf in
                    // A shelf in the list sits between two hairlines,
                    // the same gap inside each: the row's above it, and
                    // its own below to hand the list back, or the rows
                    // after it read as the shelf's.
                    shelfView(shelf)
                        .padding(.top, LadleTheme.Layout.sectionGap)
                    Divider()
                        .overlay(LadleTheme.Label.primary.opacity(0.08))
                }
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
/// same strip of steel as the failed-refresh banner: a second announcement
/// language on one screen would make the feed look like it is talking to
/// itself.
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

/// Draws a failed refresh and nothing else. A refresh in flight has no
/// indicator of its own: a pull already shows the system's control, and a
/// strip that came and went in this inset moved the feed under the reader.
struct DiscoverRefreshBanner: View {
    let state: DiscoverViewModel.RefreshState
    let retry: () -> Void

    var body: some View {
        if case let .failed(report) = state {
            DiscoverTopBar(
                systemImage: report.failure.systemImage,
                identifier: "discover.refresh-status"
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
}

/// The one bar Discover puts under the navigation bar, whatever it has to
/// say. Shared so the failed-refresh banner and the "New recipes" pill cannot
/// drift into two different pieces of furniture.
private struct DiscoverTopBar<Content: View>: View {
    let systemImage: String
    let identifier: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: LadleTheme.Layout.iconGap) {
            Image(systemName: systemImage)
                .font(.system(
                    size: LadleTheme.IconSize.medium,
                    weight: .semibold
                ))
                .accessibilityHidden(true)
            content()
        }
        .foregroundStyle(LadleTheme.Label.primary)
        .padding(.horizontal, LadleTheme.Layout.screenMargin)
        .padding(.vertical, LadleTheme.Spacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Sideways only. Left to ignore the top safe area, the fill runs up
        // under the clear navigation bar and paints over the large title.
        .background(
            LadleTheme.Surface.steel,
            ignoresSafeAreaEdges: .horizontal
        )
        .overlay(alignment: .bottom) {
            // The pill wraps this bar in a Button, and there a bare Divider
            // stands upright; the stack keeps it flat.
            VStack(spacing: 0) {
                Divider().overlay(LadleTheme.Stroke.separator)
            }
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
        ladleContextMenu {
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
    @Environment(\.ladleAccent) private var accent

    let shelf: DiscoverShelf
    let isLoadingDetail: (DiscoverRecipe) -> Bool
    let isSaved: (DiscoverRecipe) -> Bool
    let open: (DiscoverRecipe) -> Void
    let save: (DiscoverRecipe) -> Void
    let showAll: (RecipeKeyword) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
            header

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

    /// The title, whatever it has to say for itself, and the way out of the
    /// row. Only a keyword shelf has one: a keyword is a filter, so "See
    /// all" has somewhere to go, while "New to Overeasy" is an ordering
    /// nothing in the app can ask for a second time.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shelf.title)
                    .ladleFont(.section)
                    .foregroundStyle(LadleTheme.Label.primary)
                if let caption = shelf.caption {
                    Text(caption)
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.Label.secondary)
                }
            }
            if let keyword = shelf.keyword {
                Spacer(minLength: LadleTheme.Spacing.medium)
                Button("See all") { showAll(keyword) }
                    .ladleFont(.bodyStrong)
                    .buttonStyle(.plain)
                    .foregroundStyle(accent.intent)
                    .accessibilityIdentifier(
                        "discover.shelf.\(shelf.id.slug).see-all"
                    )
                    .accessibilityLabel("See all \(shelf.title)")
            }
        }
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
            "discover.card.\(shelf.slug).\(recipe.originalURL.absoluteString)"
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
            // Beneath the loading veil, which is gone by the time the page
            // opens and has no place in the zoom.
            .recipeZoomSource(
                RecipeZoomID(recipe.sourceID, shelf: shelf),
                cornerRadius: LadleTheme.Corner.thumbnail
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

struct DiscoverRecipeRow: View {
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
                engagementLine
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
        .recipeZoomSource(
            RecipeZoomID(recipe.sourceID),
            cornerRadius: LadleTheme.Corner.control
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

    var saveButton: some View {
        Button(action: save) {
            Label(
                isSaved ? "Saved" : "Save",
                systemImage: isSaved ? "checkmark" : "plus"
            )
        }
        .buttonStyle(LadleButtonStyle(
            role: isSaved ? .secondary : .primary,
            isFullWidth: false,
            isLoading: isSaving
        ))
        .disabled(isSaving || isSaved)
        // Keyed on saving: the fill drops and the spinner comes in on the
        // curve at the tap. A save that lands takes the row away with it.
        .ladleAnimation(value: isSaving)
        .accessibilityLabel(
            isSaved ? "\(recipe.title) saved" : "Save \(recipe.title)"
        )
    }

    /// Overeasy's own numbers: stars once the server publishes an average,
    /// then the saves. Under Most liked the row shows the number it is
    /// ranked by instead; anything else there would leave the order looking
    /// arbitrary.
    @ViewBuilder
    private var engagementLine: some View {
        let text = EngagementText(recipe)
        if sort == .mostLiked, let likes = text.likes {
            Text(likes)
        } else {
            EngagementLine(text: text)
        }
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
