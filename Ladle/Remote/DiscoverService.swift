import Foundation
import LadleCore

struct SavedDiscoverRecipe: Equatable, Sendable {
    let recipe: Recipe
    let revision: Int
}

@MainActor
protocol DiscoverServing {
    func fetchDiscoverRecipes() async throws -> [DiscoverRecipe]
    func saveDiscoverRecipe(
        sourceID: UUID
    ) async throws -> SavedDiscoverRecipe
}

struct RemoteDiscoverService: DiscoverServing {
    let api: APIClient

    func fetchDiscoverRecipes() async throws -> [DiscoverRecipe] {
        let page: RemoteDiscoverPageDTO = try await api.request(
            path: "/v1/recipes/discover"
        )
        return page.items.map { $0.recipe() }
    }

    func saveDiscoverRecipe(
        sourceID: UUID
    ) async throws -> SavedDiscoverRecipe {
        let remote: RemoteRecipeDTO = try await api.request(
            path: "/v1/recipes/discover/\(sourceID.uuidString)/save",
            method: .post
        )
        return SavedDiscoverRecipe(
            recipe: try remote.recipe(),
            revision: remote.revision
        )
    }
}

struct DemoDiscoverService: DiscoverServing {
    func fetchDiscoverRecipes() async throws -> [DiscoverRecipe] {
        PreviewFixtures.recipes.enumerated().map { index, recipe in
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
