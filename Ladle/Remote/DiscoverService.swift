import LadleCore

@MainActor
protocol DiscoverServing {
    func fetchDiscoverRecipes() async throws -> [DiscoverRecipe]
}

struct RemoteDiscoverService: DiscoverServing {
    let api: APIClient

    func fetchDiscoverRecipes() async throws -> [DiscoverRecipe] {
        let page: RemoteDiscoverPageDTO = try await api.request(
            path: "/v1/recipes/discover"
        )
        return page.items.map { $0.recipe() }
    }
}

struct DemoDiscoverService: DiscoverServing {
    func fetchDiscoverRecipes() async throws -> [DiscoverRecipe] {
        PreviewFixtures.recipes.enumerated().map { index, recipe in
            DiscoverRecipe(
                title: recipe.title,
                description: recipe.description,
                creatorName: recipe.creatorName,
                source: recipe.source,
                originalURL: recipe.originalURL,
                imageURL: recipe.images.first?.remoteURL,
                savedCount: max(2, 18 - (index * 3))
            )
        }
    }
}
