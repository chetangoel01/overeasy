import Foundation
import LadleCore

@MainActor
protocol RecipeRepository {
    func fetchRecipes() throws -> [Recipe]
    func fetchRecipe(id: UUID) throws -> Recipe?
    func save(_ recipe: Recipe) throws
    func deleteRecipe(id: UUID) throws

    func fetchImportJobs() throws -> [ImportJob]
    func save(_ importJob: ImportJob) throws
    func replaceRecipe(
        id: UUID,
        with recipe: Recipe,
        completing importJob: ImportJob
    ) throws

    func seedIfNeeded(
        recipes: [Recipe],
        importJobs: [ImportJob]
    ) throws
}

extension RecipeRepository {
    func replaceRecipe(
        id: UUID,
        with recipe: Recipe,
        completing importJob: ImportJob
    ) throws {
        try save(recipe)
        try save(importJob)
        try deleteRecipe(id: id)
    }
}
