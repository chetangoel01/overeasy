import Foundation
import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class RecipeEditorViewModelTests: XCTestCase {
    func testDraftCopiesEveryStructuredRecipeSection() {
        let recipe = PreviewFixtures.recipes[1]
        let viewModel = makeViewModel(recipe: recipe)

        XCTAssertEqual(viewModel.draft.id, recipe.id)
        XCTAssertEqual(viewModel.draft.title, recipe.title)
        XCTAssertEqual(viewModel.draft.creatorName, recipe.creatorName ?? "")
        XCTAssertEqual(viewModel.draft.preparationMinutes, "10")
        XCTAssertEqual(viewModel.draft.cookingMinutes, "25")
        XCTAssertEqual(viewModel.draft.servings, "4")
        XCTAssertEqual(
            viewModel.draft.ingredients.map(\.id),
            recipe.orderedIngredients.map(\.id)
        )
        XCTAssertEqual(
            viewModel.draft.steps.map(\.id),
            recipe.orderedSteps.map(\.id)
        )
        XCTAssertEqual(viewModel.draft.nutrition.calories, "520")
        XCTAssertTrue(viewModel.draft.nutrition.isEstimated)
    }

    func testIngredientAndStepEditsPreserveExplicitOrdering() {
        let viewModel = makeViewModel()

        viewModel.addIngredient()
        let newIngredientID = viewModel.draft.ingredients.last?.id
        viewModel.draft.ingredients[
            viewModel.draft.ingredients.count - 1
        ].name = "fresh basil"
        viewModel.moveIngredient(
            from: viewModel.draft.ingredients.count - 1,
            to: 0
        )

        viewModel.addStep()
        let newStepID = viewModel.draft.steps.last?.id
        viewModel.draft.steps[viewModel.draft.steps.count - 1]
            .instruction = "Finish with basil."
        viewModel.moveStep(
            from: viewModel.draft.steps.count - 1,
            to: 0
        )

        XCTAssertEqual(
            viewModel.draft.ingredients.first?.id,
            newIngredientID
        )
        XCTAssertEqual(viewModel.draft.ingredients.first?.name, "fresh basil")
        XCTAssertEqual(viewModel.draft.steps.first?.id, newStepID)
        XCTAssertEqual(
            viewModel.draft.steps.first?.instruction,
            "Finish with basil."
        )
    }

    func testInvalidStructuredFieldsStayInlineAndDoNotPersist() {
        let repository = EditorTestRepository(
            recipes: [PreviewFixtures.recipes[1]]
        )
        let viewModel = makeViewModel(repository: repository)
        viewModel.draft.title = "  "
        viewModel.draft.servings = "zero"
        viewModel.draft.ingredients[0].name = ""
        viewModel.draft.steps[0].instruction = ""

        let saved = viewModel.save()

        XCTAssertNil(saved)
        XCTAssertTrue(
            viewModel.validationIssues.contains(.titleRequired)
        )
        XCTAssertTrue(
            viewModel.validationIssues.contains(.servingsMustBePositive)
        )
        XCTAssertTrue(
            viewModel.validationIssues.contains(
                .ingredientNameRequired(
                    viewModel.draft.ingredients[0].id
                )
            )
        )
        XCTAssertTrue(
            viewModel.validationIssues.contains(
                .stepInstructionRequired(viewModel.draft.steps[0].id)
            )
        )
        XCTAssertEqual(repository.saveCount, 0)
    }

    func testDiscardRestoresOriginalWithoutPersisting() {
        let recipe = PreviewFixtures.recipes[1]
        let repository = EditorTestRepository(recipes: [recipe])
        let viewModel = makeViewModel(
            recipe: recipe,
            repository: repository
        )
        viewModel.draft.title = "Unsaved title"

        viewModel.discardChanges()

        XCTAssertEqual(viewModel.draft.title, recipe.title)
        XCTAssertEqual(repository.saveCount, 0)
        XCTAssertEqual(repository.recipes, [recipe])
    }

    func testSavePreservesStableIdentityAndUpdatesRepository() throws {
        let recipe = PreviewFixtures.recipes[1]
        let repository = EditorTestRepository(recipes: [recipe])
        let viewModel = makeViewModel(
            recipe: recipe,
            repository: repository
        )
        viewModel.draft.title = "Creamy Lemon Orzo"
        viewModel.draft.ingredients[0].quantityText = "1½"

        let saved = try XCTUnwrap(viewModel.save())

        XCTAssertEqual(saved.id, recipe.id)
        XCTAssertEqual(saved.createdAt, recipe.createdAt)
        XCTAssertEqual(saved.title, "Creamy Lemon Orzo")
        XCTAssertEqual(saved.orderedIngredients[0].quantityText, "1½")
        XCTAssertEqual(repository.recipes, [saved])
        XCTAssertEqual(repository.saveCount, 1)
    }

    private func makeViewModel(
        recipe: Recipe = PreviewFixtures.recipes[1],
        repository: EditorTestRepository? = nil
    ) -> RecipeEditorViewModel {
        RecipeEditorViewModel(
            recipe: recipe,
            repository: repository
                ?? EditorTestRepository(recipes: [recipe]),
            now: {
                Date(timeIntervalSince1970: 1_784_900_000)
            }
        )
    }
}

@MainActor
private final class EditorTestRepository: RecipeRepository {
    var recipes: [Recipe]
    var importJobs: [ImportJob] = []
    var saveCount = 0

    init(recipes: [Recipe]) {
        self.recipes = recipes
    }

    func fetchRecipes() throws -> [Recipe] {
        recipes
    }

    func fetchRecipe(id: UUID) throws -> Recipe? {
        recipes.first { $0.id == id }
    }

    func save(_ recipe: Recipe) throws {
        saveCount += 1
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
    }

    func deleteRecipe(id: UUID) throws {
        recipes.removeAll { $0.id == id }
    }

    func fetchImportJobs() throws -> [ImportJob] {
        importJobs
    }

    func save(_ importJob: ImportJob) throws {
        if let index = importJobs.firstIndex(
            where: { $0.id == importJob.id }
        ) {
            importJobs[index] = importJob
        } else {
            importJobs.append(importJob)
        }
    }

    func seedIfNeeded(
        recipes: [Recipe],
        importJobs: [ImportJob]
    ) throws {}
}
