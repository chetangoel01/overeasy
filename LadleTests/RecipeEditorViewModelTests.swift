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

    /// The reviewer's repro: the offending field lives in a section the user
    /// is not looking at, so the inline message is off screen and the Save
    /// tap reads as a dead button.
    func testSaveRejectedForAnOffScreenFieldStillNamesWhereToLook() {
        let viewModel = makeViewModel()
        viewModel.addStep()

        XCTAssertNil(viewModel.save(), "A blank step must block the save")

        let summary = viewModel.validationSummary
        XCTAssertNotNil(
            summary,
            "A rejected save must surface a summary, or the tap looks like a no-op"
        )
        XCTAssertEqual(summary?.sections, [.method])
        XCTAssertEqual(
            summary?.headline,
            "Can't save yet — one field needs attention"
        )
        XCTAssertEqual(summary?.detail, "Check Method.")
    }

    func testSummaryNamesEverySectionHoldingARejectedFieldInTabOrder() {
        let viewModel = makeViewModel()
        // Seeded out of tab order on purpose: Method first, then Basics.
        viewModel.addStep()
        viewModel.draft.title = "   "

        XCTAssertNil(viewModel.save())

        let summary = viewModel.validationSummary
        XCTAssertEqual(
            summary?.sections,
            [.basics, .method],
            "Sections must be listed in tab order, not issue order"
        )
        XCTAssertEqual(
            summary?.headline,
            "Can't save yet — 2 fields need attention"
        )
        XCTAssertEqual(summary?.detail, "Check Basics and Method.")
    }

    func testAValidDraftHasNoSummaryBeforeOrAfterSaving() throws {
        let viewModel = makeViewModel()

        XCTAssertNil(
            viewModel.validationSummary,
            "An untouched draft has not been rejected, so there is nothing to say"
        )
        XCTAssertNotNil(viewModel.save())
        XCTAssertNil(viewModel.validationSummary)
    }

    func testFixingTheRejectedFieldClearsTheSummary() throws {
        let viewModel = makeViewModel()
        viewModel.addStep()
        XCTAssertNil(viewModel.save())
        XCTAssertNotNil(viewModel.validationSummary)

        let added = try XCTUnwrap(viewModel.draft.steps.indices.last)
        viewModel.draft.steps[added].instruction =
            "Rest the dough for twenty minutes."

        XCTAssertNotNil(viewModel.save())
        XCTAssertNil(viewModel.validationSummary)
        XCTAssertTrue(viewModel.sectionsNeedingAttention.isEmpty)
    }

    /// Every issue the draft can raise must map to a section, or a rejected
    /// save could produce a summary that names nowhere.
    func testEveryValidationIssueBelongsToASection() {
        let identifier = UUID()
        let issues: [RecipeDraftValidationIssue] = [
            .titleRequired, .titleTooLong, .creatorNameTooLong,
            .descriptionTooLong, .servingsMustBePositive,
            .preparationMinutesInvalid, .cookingMinutesInvalid,
            .totalMinutesInvalid, .tooManyIngredients, .tooManySteps,
            .ingredientNameRequired(identifier),
            .ingredientFieldTooLong(identifier),
            .stepInstructionRequired(identifier),
            .stepInstructionTooLong(identifier),
            .nutritionValueInvalid("calories"),
        ]
        for issue in issues {
            XCTAssertTrue(
                RecipeEditorSection.allCases
                    .contains(RecipeEditorSection.owning(issue)),
                "\(issue) maps outside the editor's sections"
            )
        }
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

    func testServerContractLimitsStayInlineAndDoNotPersist() {
        let repository = EditorTestRepository(
            recipes: [PreviewFixtures.recipes[1]]
        )
        let viewModel = makeViewModel(repository: repository)
        let ingredientID = viewModel.draft.ingredients[0].id
        let stepID = viewModel.draft.steps[0].id
        viewModel.draft.title = String(repeating: "x", count: 301)
        viewModel.draft.creatorName = String(repeating: "x", count: 201)
        viewModel.draft.description = String(repeating: "x", count: 10_001)
        viewModel.draft.preparationMinutes = "43201"
        viewModel.draft.cookingMinutes = "43201"
        viewModel.draft.servings = "10001"
        viewModel.draft.ingredients[0].quantityText =
            String(repeating: "x", count: 101)
        viewModel.draft.ingredients[0].unit =
            String(repeating: "x", count: 51)
        viewModel.draft.ingredients[0].name =
            String(repeating: "x", count: 301)
        viewModel.draft.ingredients[0].preparation =
            String(repeating: "x", count: 501)
        viewModel.draft.steps[0].instruction =
            String(repeating: "x", count: 5_001)
        viewModel.draft.nutrition.isIncluded = true
        viewModel.draft.nutrition.calories = "1000001"

        XCTAssertNil(viewModel.save())
        XCTAssertTrue(viewModel.validationIssues.contains(.titleTooLong))
        XCTAssertTrue(viewModel.validationIssues.contains(.creatorNameTooLong))
        XCTAssertTrue(viewModel.validationIssues.contains(.descriptionTooLong))
        XCTAssertTrue(
            viewModel.validationIssues.contains(.preparationMinutesInvalid)
        )
        XCTAssertTrue(
            viewModel.validationIssues.contains(.cookingMinutesInvalid)
        )
        XCTAssertTrue(
            viewModel.validationIssues.contains(.totalMinutesInvalid)
        )
        XCTAssertTrue(
            viewModel.validationIssues.contains(.servingsMustBePositive)
        )
        XCTAssertTrue(
            viewModel.validationIssues.contains(
                .ingredientFieldTooLong(ingredientID)
            )
        )
        XCTAssertTrue(
            viewModel.validationIssues.contains(
                .stepInstructionTooLong(stepID)
            )
        )
        XCTAssertTrue(
            viewModel.validationIssues.contains(
                .nutritionValueInvalid("Calories")
            )
        )
        XCTAssertEqual(repository.saveCount, 0)
    }

    func testEditorCannotAddMoreThanServerCollectionLimits() {
        let viewModel = makeViewModel()
        while viewModel.draft.ingredients.count < 200 {
            viewModel.addIngredient()
        }
        while viewModel.draft.steps.count < 200 {
            viewModel.addStep()
        }

        viewModel.addIngredient()
        viewModel.addStep()

        XCTAssertEqual(viewModel.draft.ingredients.count, 200)
        XCTAssertEqual(viewModel.draft.steps.count, 200)
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

    func testCommaDecimalLocaleSavesTheYieldTheUserTyped() throws {
        let repository = EditorTestRepository(
            recipes: [PreviewFixtures.recipes[1]]
        )
        let viewModel = makeViewModel(
            repository: repository,
            locale: Locale(identifier: "fr_FR")
        )
        // The .decimalPad renders this locale's separator, so this is what
        // the comma key produces.
        viewModel.draft.servings = "1,5"
        viewModel.draft.nutrition.calories = "12,5"

        let saved = try XCTUnwrap(viewModel.save())

        XCTAssertTrue(viewModel.validationIssues.isEmpty)
        XCTAssertEqual(saved.servings, Decimal(string: "1.5"))
        XCTAssertEqual(
            saved.nutrition?.calories,
            Decimal(string: "12.5")
        )
    }

    func testUnparseableNumbersAreRejectedRatherThanTruncated() {
        let repository = EditorTestRepository(
            recipes: [PreviewFixtures.recipes[1]]
        )
        let viewModel = makeViewModel(repository: repository)
        viewModel.draft.servings = "1.2.3"
        viewModel.draft.nutrition.calories = "12abc"

        let saved = viewModel.save()

        XCTAssertNil(saved)
        XCTAssertTrue(
            viewModel.validationIssues.contains(.servingsMustBePositive)
        )
        XCTAssertTrue(
            viewModel.validationIssues.contains(
                .nutritionValueInvalid("Calories")
            )
        )
        XCTAssertEqual(repository.saveCount, 0)
    }

    private func makeViewModel(
        recipe: Recipe = PreviewFixtures.recipes[1],
        repository: EditorTestRepository? = nil,
        locale: Locale = Locale(identifier: "en_US")
    ) -> RecipeEditorViewModel {
        RecipeEditorViewModel(
            recipe: recipe,
            repository: repository
                ?? EditorTestRepository(recipes: [recipe]),
            now: {
                Date(timeIntervalSince1970: 1_784_900_000)
            },
            locale: locale
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
