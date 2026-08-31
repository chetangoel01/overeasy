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
    case alphabetical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popular: "Most saved"
        case .alphabetical: "A to Z"
        }
    }

    var systemImage: String {
        switch self {
        case .popular: "bookmark.fill"
        case .alphabetical: "textformat.abc"
        }
    }

    /// What the feed header promises under this order.
    var caption: String {
        switch self {
        case .popular: "Popular public recipe videos, ranked by saves."
        case .alphabetical: "Every public recipe video, A to Z."
        }
    }
}

enum DiscoverPaging {
    /// Mirrors the server's default page size.
    static let pageSize = 30
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
        sort: DiscoverSort
    ) async throws -> DiscoverPage
    func fetchDiscoverRecipe(sourceID: UUID) async throws -> Recipe
    func saveDiscoverRecipe(
        sourceID: UUID
    ) async throws -> SavedDiscoverRecipe
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

    func fetchDiscoverPage(
        cursor: Int,
        query: String,
        sort: DiscoverSort
    ) async throws -> DiscoverPage {
        var items = [
            URLQueryItem(name: "cursor", value: String(cursor)),
            URLQueryItem(name: "sort", value: sort.rawValue),
        ]
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

    init(scenario: DemoLaunchScenario = .standard) {
        self.scenario = scenario
    }

    /// Mirrors the server: filters and orders the whole fixture set, then
    /// returns one page. Without that the demo would not exercise paging.
    func fetchDiscoverPage(
        cursor: Int,
        query: String,
        sort: DiscoverSort
    ) async throws -> DiscoverPage {
        if scenario == .discoverEmpty {
            return .empty
        }
        if scenario == .discoverRateLimited {
            throw DemoRemoteError.rateLimited
        }
        let all = PreviewFixtures.recipes.enumerated().map { index, recipe in
            DiscoverRecipe(
                sourceID: recipe.id,
                title: recipe.title,
                description: recipe.description,
                creatorName: recipe.creatorName,
                source: recipe.source,
                originalURL: recipe.originalURL,
                imageURL: recipe.images.first?.remoteURL,
                savedCount: max(2, 18 - (index * 3)),
                savedRecipeID: nil
            )
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = trimmed.isEmpty
            ? all
            : all.filter { $0.matches(trimmed) }
        let ordered = switch sort {
        case .popular:
            matched.sorted { $0.savedCount > $1.savedCount }
        case .alphabetical:
            matched.sorted { first, second in
                first.title.localizedCaseInsensitiveCompare(second.title)
                    == .orderedAscending
            }
        }
        let limit = DiscoverPaging.pageSize
        let start = min(cursor, ordered.count)
        let end = min(start + limit, ordered.count)
        return DiscoverPage(
            recipes: Array(ordered[start..<end]),
            nextCursor: end,
            hasMore: end < ordered.count
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
