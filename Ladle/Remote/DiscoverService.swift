import Foundation
import LadleCore

struct SavedDiscoverRecipe: Equatable, Sendable {
    let recipe: Recipe
    let revision: Int
}

@MainActor
protocol DiscoverServing {
    func fetchDiscoverRecipes() async throws -> [DiscoverRecipe]
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

    func fetchDiscoverRecipes() async throws -> [DiscoverRecipe] {
        let page: RemoteDiscoverPageDTO = try await api.request(
            path: "/v1/recipes/discover"
        )
        return page.items.map { $0.recipe() }
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

    func fetchDiscoverRecipes() async throws -> [DiscoverRecipe] {
        if scenario == .discoverEmpty {
            return []
        }
        if scenario == .discoverRateLimited {
            throw DemoRemoteError.rateLimited
        }
        return PreviewFixtures.recipes.enumerated().map { index, recipe in
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
