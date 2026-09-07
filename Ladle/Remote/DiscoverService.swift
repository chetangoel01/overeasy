import Foundation
import LadleCore

struct SavedDiscoverRecipe: Equatable, Sendable {
    let recipe: Recipe
    let revision: Int
}

/// How the server orders the Discover feed. Ordering belongs to the server
/// now that the feed is paged — sorting one page on the client would only
/// sort that page.
enum DiscoverSort: String, CaseIterable, Identifiable, Sendable {
    case popular
    case newest
    case mostLiked
    case alphabetical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popular: "Most saved"
        case .newest: "Newest"
        case .mostLiked: "Most liked"
        case .alphabetical: "A to Z"
        }
    }

    var systemImage: String {
        switch self {
        case .popular: "bookmark.fill"
        case .newest: "clock"
        case .mostLiked: "heart.fill"
        case .alphabetical: "textformat.abc"
        }
    }

    /// What the feed header promises under this order.
    var caption: String {
        switch self {
        case .popular:
            "Popular public recipe videos, ranked by saves."
        case .newest:
            "Public recipe videos in the order they arrived in Overeasy."
        case .mostLiked:
            "Ranked by likes on the original video, counted when it was saved."
        case .alphabetical:
            "Every public recipe video, A to Z."
        }
    }
}

/// The two curated rails. Each is a first page of the same feed under a
/// different order or filter, which is why neither needs a wire model, an
/// endpoint, or a cursor of its own.
enum DiscoverRail: CaseIterable, Sendable {
    case newToOvereasy
    case quickDinners

    var id: DiscoverShelf.ID {
        switch self {
        case .newToOvereasy: .newToOvereasy
        case .quickDinners: .quickDinners
        }
    }

    var title: String {
        switch self {
        case .newToOvereasy: "New to Overeasy"
        case .quickDinners: "Quick dinners"
        }
    }

    /// A rail's title is a promise about an ordering, so it needs a line
    /// saying what the promise is. A keyword shelf's title says what is on
    /// it, and has no caption.
    var caption: String {
        switch self {
        case .newToOvereasy: "The videos that arrived here most recently."
        case .quickDinners: "Thirty minutes or less, start to finish."
        }
    }

    var sort: DiscoverSort {
        switch self {
        case .newToOvereasy: .newest
        case .quickDinners: .popular
        }
    }

    /// Nil keeps every source. A value drops the ones no saver timed —
    /// an unknown total is not a fast one.
    var maxTotalMinutes: Int? {
        switch self {
        case .newToOvereasy: nil
        case .quickDinners: 30
        }
    }
}

/// One horizontal shelf above the ranked list.
///
/// Two kinds, drawn the same way. The curated rails are named here because
/// they are orderings this app chose; a keyword shelf is named by the server,
/// because the keyword vocabulary is the server's and a shelf for a keyword
/// this build has never heard of still has to be drawable.
struct DiscoverShelf: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case newToOvereasy
        case quickDinners
        /// Keyed on the raw wire value rather than the decoded keyword, so
        /// two shelves stay distinct even when this build can name neither.
        case keyword(String)

        /// The stable part of a card's accessibility identifier.
        var slug: String {
            switch self {
            case .newToOvereasy: "newToOvereasy"
            case .quickDinners: "quickDinners"
            case let .keyword(value): "keyword-\(value)"
            }
        }
    }

    let id: ID
    let title: String
    let caption: String?
    /// The keyword this shelf was composed from, when this build knows it.
    /// Nil on the curated rails, which no filter reproduces, and on a shelf
    /// for a keyword promoted after this build shipped. It is what "See all"
    /// puts in the shared filter, so nil is also what hides that button.
    let keyword: RecipeKeyword?
    var recipes: [DiscoverRecipe]

    init(
        id: ID,
        title: String,
        caption: String? = nil,
        keyword: RecipeKeyword? = nil,
        recipes: [DiscoverRecipe]
    ) {
        self.id = id
        self.title = title
        self.caption = caption
        self.keyword = keyword
        self.recipes = recipes
    }

    init(rail: DiscoverRail, recipes: [DiscoverRecipe]) {
        self.init(
            id: rail.id,
            title: rail.title,
            caption: rail.caption,
            recipes: recipes
        )
    }

    init(shelf: RemoteDiscoverShelfDTO) {
        self.init(
            id: .keyword(shelf.keyword),
            title: shelf.title,
            keyword: shelf.recipeKeyword,
            recipes: shelf.recipes
        )
    }

    /// Below this a rail reads as an accident rather than a shelf, and the
    /// full-width list underneath already carries the same rows.
    static let minimumRecipes = 3
}

enum DiscoverPaging {
    /// Mirrors the server's default page size.
    static let pageSize = 30
    /// A shelf carries enough to cover its own window and no more. Past the
    /// end of a swipe there is nothing to reach: a curated rail has no
    /// destination at all, and a keyword shelf's "See all" opens the ranked
    /// list under that keyword rather than continuing the row.
    static let shelfSize = 10
    /// Begin the next page this many rows before the end, so scrolling does
    /// not stop at a spinner.
    static let prefetchThreshold = 8
}

extension DiscoverRecipe {
    /// Only the demo service filters locally; the real feed is searched by
    /// the server across the whole corpus.
    func matches(_ query: String) -> Bool {
        [title, description, creatorName ?? ""].contains { field in
            field.localizedCaseInsensitiveContains(query)
        }
    }
}

struct DiscoverPage: Equatable, Sendable {
    let recipes: [DiscoverRecipe]
    /// Pass back as `cursor` for the next page. Counts ranked rows consumed,
    /// not items returned, so a short page still advances paging.
    let nextCursor: Int
    let hasMore: Bool

    static let empty = DiscoverPage(recipes: [], nextCursor: 0, hasMore: false)
}

@MainActor
protocol DiscoverServing {
    func fetchDiscoverPage(
        cursor: Int,
        query: String,
        sort: DiscoverSort,
        filter: RecipeFilter,
        maxTotalMinutes: Int?,
        limit: Int,
        seenBefore: Date?,
        recordsImpressions: Bool
    ) async throws -> DiscoverPage
    /// The shelves the server composed from the keyword tags, already
    /// ordered and titled. The client draws what it is handed and composes
    /// nothing: which keywords are worth a shelf is a fact about the whole
    /// corpus, and a page of thirty rows cannot answer it.
    func fetchKeywordShelves(
        filter: RecipeFilter,
        limit: Int
    ) async throws -> [DiscoverShelf]
    func fetchDiscoverRecipe(sourceID: UUID) async throws -> Recipe
    func saveDiscoverRecipe(
        sourceID: UUID
    ) async throws -> SavedDiscoverRecipe
}

extension DiscoverServing {
    /// The feed's own page: no time filter, the server's page size. Swift
    /// protocols cannot carry default arguments, so the defaults live here
    /// and only the shelves pass the two extra values.
    ///
    /// `seenBefore` is the moment this paging session began. Sending it asks
    /// the server to sort what the cook has recently seen to the back and to
    /// record this page as seen; leaving it nil asks for neither, which is
    /// what the rails want — a rail is a ranking, not a reading position.
    ///
    /// `recordsImpressions: false` takes the first of those without the
    /// second, for the page Discover fetches quietly at the top and holds
    /// behind its pill. It is ranked against what the cook has read, but a
    /// page they have not looked at yet cannot count as read.
    func fetchDiscoverPage(
        cursor: Int,
        query: String,
        sort: DiscoverSort,
        filter: RecipeFilter = .none,
        seenBefore: Date? = nil,
        recordsImpressions: Bool = true
    ) async throws -> DiscoverPage {
        try await fetchDiscoverPage(
            cursor: cursor,
            query: query,
            sort: sort,
            filter: filter,
            maxTotalMinutes: nil,
            limit: DiscoverPaging.pageSize,
            seenBefore: seenBefore,
            recordsImpressions: recordsImpressions
        )
    }
}

/// The one Discover-detail path; RemoteImageCache refreshes expired
/// Discover thumbnails through the same endpoint.
enum DiscoverAPI {
    static func detailPath(sourceID: UUID) -> String {
        "/v1/recipes/discover/\(sourceID.uuidString)"
    }
}

struct RemoteDiscoverService: DiscoverServing {
    let api: APIClient

    /// UTC with fractional seconds, the same shape the response decoder
    /// expects on the way back, so a timestamp means one thing in both
    /// directions.
    private static let seenBeforeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    func fetchDiscoverPage(
        cursor: Int,
        query: String,
        sort: DiscoverSort,
        filter: RecipeFilter,
        maxTotalMinutes: Int?,
        limit: Int,
        seenBefore: Date?,
        recordsImpressions: Bool
    ) async throws -> DiscoverPage {
        var items = [
            URLQueryItem(name: "cursor", value: String(cursor)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: sort.rawValue),
        ]
        items += Self.filterItems(filter)
        if let maxTotalMinutes {
            items.append(
                URLQueryItem(
                    name: "max_total_minutes",
                    value: String(maxTotalMinutes)
                )
            )
        }
        if let seenBefore {
            items.append(
                URLQueryItem(
                    name: "seen_before",
                    value: Self.seenBeforeFormatter.string(from: seenBefore)
                )
            )
        }
        // Only where it means something: the server records nothing without
        // a pin and defaults to recording with one, so the shelves and the
        // ordinary page keep the request shape they already had.
        if seenBefore != nil, !recordsImpressions {
            items.append(
                URLQueryItem(name: "record_impressions", value: "false")
            )
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "q", value: trimmed))
        }
        var components = URLComponents()
        components.path = "/v1/recipes/discover"
        components.queryItems = items
        let page: RemoteDiscoverPageDTO = try await api.request(
            path: components.url?.absoluteString ?? "/v1/recipes/discover"
        )
        return DiscoverPage(
            recipes: page.items.map { $0.recipe() },
            nextCursor: page.nextCursor,
            hasMore: page.hasMore
        )
    }

    func fetchKeywordShelves(
        filter: RecipeFilter,
        limit: Int
    ) async throws -> [DiscoverShelf] {
        var components = URLComponents()
        components.path = "/v1/recipes/discover/shelves"
        // The same filter the feed answers. A shelf composed for everybody
        // and shown to a vegetarian would be a row of food they cannot eat
        // under a title chosen for somebody else.
        components.queryItems =
            [URLQueryItem(name: "limit", value: String(limit))]
            + Self.filterItems(filter)
        let shelves: RemoteDiscoverShelvesDTO = try await api.request(
            path: components.url?.absoluteString
                ?? "/v1/recipes/discover/shelves"
        )
        return shelves.shelves.map { DiscoverShelf(shelf: $0) }
    }

    /// One repeated parameter per chosen tag, in vocabulary order.
    ///
    /// The families mean different things to the server — every `diet` and
    /// every `ingredient` must hold, any `cuisine` or `keyword` will do —
    /// and none of that is encoded here: repeating the name is the whole
    /// wire format, and the meaning lives in the endpoint. Values are the
    /// enum's raw strings, so an off-vocabulary term cannot be spelled.
    static func filterItems(_ filter: RecipeFilter) -> [URLQueryItem] {
        filter.orderedDiets.map {
            URLQueryItem(name: "diet", value: $0.rawValue)
        }
            + filter.orderedCuisines.map {
                URLQueryItem(name: "cuisine", value: $0.rawValue)
            }
            + filter.orderedKeywords.map {
                URLQueryItem(name: "keyword", value: $0.rawValue)
            }
            + filter.ingredients.map {
                URLQueryItem(name: "ingredient", value: $0)
            }
    }

    func fetchDiscoverRecipe(sourceID: UUID) async throws -> Recipe {
        let remote: RemoteRecipeDTO = try await api.request(
            path: DiscoverAPI.detailPath(sourceID: sourceID)
        )
        return try remote.recipe()
    }

    func saveDiscoverRecipe(
        sourceID: UUID
    ) async throws -> SavedDiscoverRecipe {
        let remote: RemoteRecipeDTO = try await api.request(
            path: DiscoverAPI.detailPath(sourceID: sourceID) + "/save",
            method: .post
        )
        return SavedDiscoverRecipe(
            recipe: try remote.recipe(),
            revision: remote.revision
        )
    }
}

struct DemoDiscoverService: DiscoverServing {
    let scenario: DemoLaunchScenario

    /// Fixture order stands in for arrival order, so "newest" has something
    /// deterministic to rank by without inventing a date on the wire model.
    private static let arrivalOrder: [UUID: Int] = Dictionary(
        uniqueKeysWithValues: PreviewFixtures.recipes.enumerated().map {
            ($0.element.id, $0.offset)
        }
    )

    init(scenario: DemoLaunchScenario = .standard) {
        self.scenario = scenario
    }

    /// Mirrors the server: filters and orders the whole fixture set, then
    /// returns one page. Without that the demo would not exercise paging —
    /// or, since #29, the two shelves, which are exactly this call under a
    /// different order and a time filter.
    ///
    /// `seenBefore` and `recordsImpressions` are accepted and ignored. The
    /// demo keeps no per-cook state and the UI tests need the same rows on
    /// every launch, which is exactly what a feed that reorders itself
    /// between sessions would destroy — and the reason the "New recipes"
    /// pill never appears in a demo scenario: a quiet refresh here always
    /// hands back the page already on screen.
    func fetchDiscoverPage(
        cursor: Int,
        query: String,
        sort: DiscoverSort,
        filter: RecipeFilter,
        maxTotalMinutes: Int?,
        limit: Int,
        seenBefore: Date?,
        recordsImpressions: Bool
    ) async throws -> DiscoverPage {
        if scenario == .discoverEmpty {
            return .empty
        }
        if scenario == .discoverRateLimited {
            throw DemoRemoteError.rateLimited
        }
        let all = PreviewFixtures.recipes.filter { recipe in
            // The tag filter is the server's work in a real build, so the
            // demo has to do it here or a UI run would show a filter that
            // changes nothing.
            guard filter.matches(recipe) else { return false }
            guard let maxTotalMinutes else { return true }
            // Same rule as the server: a recipe with no stated time at all is
            // left out rather than assumed quick, but one that states only a
            // cook time is judged on that.
            guard let time = recipe.displayedTime else { return false }
            return time.minutes <= maxTotalMinutes
        }.map(Self.card)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = trimmed.isEmpty
            ? all
            : all.filter { $0.matches(trimmed) }
        let ordered = switch sort {
        case .popular:
            matched.sorted { $0.savedCount > $1.savedCount }
        case .newest:
            // Last fixture first, which is the reverse of the save ranking,
            // so the "New to Overeasy" rail is visibly not the list below it.
            matched.sorted { first, second in
                Self.arrivalOrder[first.sourceID, default: 0]
                    > Self.arrivalOrder[second.sourceID, default: 0]
            }
        case .mostLiked:
            // Same rule as the server: counted videos first, then save order.
            matched.sorted { first, second in
                switch (first.likeCount, second.likeCount) {
                case let (left?, right?) where left != right:
                    left > right
                case (nil, .some):
                    false
                case (.some, nil):
                    true
                default:
                    first.savedCount > second.savedCount
                }
            }
        case .alphabetical:
            matched.sorted { first, second in
                first.title.localizedCaseInsensitiveCompare(second.title)
                    == .orderedAscending
            }
        }
        let start = min(cursor, ordered.count)
        let end = min(start + limit, ordered.count)
        return DiscoverPage(
            recipes: Array(ordered[start..<end]),
            nextCursor: end,
            hasMore: end < ordered.count
        )
    }

    /// Composes the shelves the way the server composes them, because in a
    /// demo run this *is* the server: the same floor, the same order, and
    /// the cook's filter applied before anything is counted. Without it a UI
    /// run would show two rails and no shelves, which is not the screen.
    func fetchKeywordShelves(
        filter: RecipeFilter,
        limit: Int
    ) async throws -> [DiscoverShelf] {
        guard scenario != .discoverEmpty else { return [] }
        let matching = PreviewFixtures.recipes.filter(filter.matches)
        let counted = RecipeKeyword.allCases.enumerated().map { rank, keyword in
            (rank, keyword, matching.filter { $0.keywords.contains(keyword) })
        }
        return counted
            .filter { $0.2.count >= DiscoverShelf.minimumRecipes }
            // Count first, then the vocabulary, which is the server's order
            // and the only one that does not move between launches.
            .sorted { left, right in
                left.2.count == right.2.count
                    ? left.0 < right.0
                    : left.2.count > right.2.count
            }
            .map { _, keyword, recipes in
                DiscoverShelf(
                    id: .keyword(keyword.rawValue),
                    title: keyword.title,
                    keyword: keyword,
                    recipes: recipes.prefix(limit).map(Self.card)
                )
            }
    }

    /// A fixture recipe as a Discover card.
    ///
    /// Keyed on fixture position rather than on where the recipe landed in
    /// the result, so a dish keeps its save and like counts whatever a filter
    /// removed and whichever shelf it is drawn on.
    private static func card(_ recipe: Recipe) -> DiscoverRecipe {
        let index = arrivalOrder[recipe.id, default: 0]
        return DiscoverRecipe(
            sourceID: recipe.id,
            title: recipe.title,
            description: recipe.description,
            creatorName: recipe.creatorName,
            source: recipe.source,
            originalURL: recipe.originalURL,
            imageURL: recipe.images.first?.remoteURL,
            savedCount: max(2, 18 - (index * 3)),
            // Deliberately not the save order, so Most liked is visibly a
            // different ranking in the demo. The last fixture has none,
            // standing in for a video imported before counts existed.
            likeCount: index == PreviewFixtures.recipes.count - 1
                ? nil
                : (index + 1) * 12_400,
            savedRecipeID: nil
        )
    }

    func fetchDiscoverRecipe(sourceID: UUID) async throws -> Recipe {
        guard let recipe = PreviewFixtures.recipes.first(
            where: { $0.id == sourceID }
        ) else {
            throw APIError.invalidResponse
        }
        return recipe
    }

    func saveDiscoverRecipe(
        sourceID: UUID
    ) async throws -> SavedDiscoverRecipe {
        guard let recipe = PreviewFixtures.recipes.first(
            where: { $0.id == sourceID }
        ) else {
            throw APIError.invalidResponse
        }
        return SavedDiscoverRecipe(recipe: recipe, revision: 1)
    }
}
