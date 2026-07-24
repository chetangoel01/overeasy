import SwiftData

@MainActor
final class AppEnvironment {
    let modelContainer: ModelContainer
    let recipeRepository: SwiftDataRecipeRepository

    init(isStoredInMemoryOnly: Bool = false) throws {
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )
        let container = try ModelContainer(
            for: StoredRecipe.self,
            StoredImportJob.self,
            configurations: configuration
        )
        modelContainer = container
        recipeRepository = SwiftDataRecipeRepository(
            modelContext: container.mainContext
        )
    }

    func seedPreviewDataIfNeeded() throws {
        try recipeRepository.seedIfNeeded(
            recipes: PreviewFixtures.recipes,
            importJobs: PreviewFixtures.importJobs
        )
    }

    /// Installs that predate the remote backend carried seeded demo
    /// content in their local store; clear it out once.
    func purgeDemoFixtures() throws {
        for recipe in PreviewFixtures.recipes {
            try recipeRepository.deleteRecipe(id: recipe.id)
        }
        for job in PreviewFixtures.importJobs {
            try recipeRepository.deleteImportJob(id: job.id)
        }
    }
}
