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

    func seedIfNeeded(
        recipes: [Recipe],
        importJobs: [ImportJob]
    ) throws
}
