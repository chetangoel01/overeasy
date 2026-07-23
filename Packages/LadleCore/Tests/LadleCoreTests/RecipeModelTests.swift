import Foundation
import Testing
@testable import LadleCore

@Suite("Recipe models")
struct RecipeModelTests {
    @Test
    func recipePreservesOrderedIngredientsAndSteps() {
        let salt = Ingredient(
            quantityText: "1",
            unit: "tsp",
            name: "sea salt",
            orderIndex: 1
        )
        let orzo = Ingredient(
            quantityText: "1",
            unit: "cup",
            name: "orzo",
            orderIndex: 0
        )
        let simmer = RecipeStep(
            orderIndex: 1,
            instruction: "Simmer until tender."
        )
        let toast = RecipeStep(
            orderIndex: 0,
            instruction: "Toast the orzo."
        )

        let recipe = Recipe(
            title: "Lemon Orzo",
            source: .instagram,
            originalURL: URL(string: "https://www.instagram.com/reel/example")!,
            servings: 4,
            ingredients: [salt, orzo],
            steps: [simmer, toast]
        )

        #expect(recipe.orderedIngredients.map(\.name) == ["orzo", "sea salt"])
        #expect(recipe.orderedSteps.map(\.instruction) == [
            "Toast the orzo.",
            "Simmer until tender.",
        ])
    }

    @Test
    func nutritionRecordsEstimateAndServingBasis() {
        let nutrition = Nutrition(
            calories: 520,
            proteinGrams: 18,
            servingBasis: 1,
            isEstimated: true
        )

        #expect(nutrition.calories == 520)
        #expect(nutrition.servingBasis == 1)
        #expect(nutrition.isEstimated)
    }

    @Test
    func uncertaintyIdentifiesQuestionableField() {
        let uncertainty = FieldUncertainty(
            field: "ingredients[1].quantity",
            reason: "The quantity was difficult to hear.",
            confidence: 0.42
        )

        #expect(uncertainty.field == "ingredients[1].quantity")
        #expect(uncertainty.confidence == 0.42)
    }
}
