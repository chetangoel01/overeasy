import Foundation
import LadleCore

@MainActor
protocol RecipeRepository {
    func fetchRecipes() throws -> [Recipe]
    func fetchRecipe(id: UUID) throws -> Recipe?
    func save(_ recipe: Recipe) throws
    func saveRemote(_ recipe: Recipe, revision: Int) throws
    func deleteRecipe(id: UUID) throws

    func fetchImportJobs() throws -> [ImportJob]
    func save(_ importJob: ImportJob) throws
    func deleteImportJob(id: UUID) throws

    func seedIfNeeded(
        recipes: [Recipe],
        importJobs: [ImportJob]
    ) throws
}

extension RecipeRepository {
    func saveRemote(_ recipe: Recipe, revision: Int) throws {
        try save(recipe)
    }

    func deleteImportJob(id: UUID) throws {}
}
