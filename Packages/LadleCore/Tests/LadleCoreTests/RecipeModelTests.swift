import Foundation
import Testing
@testable import LadleCore

@Suite("Recipe models")
struct RecipeModelTests {
    /// The local library is a stored blob of this type, so its decoder is
    /// what a build upgrade actually runs. A recipe saved before tags
    /// existed has to load untagged, and one saved by a build that knew a
    /// keyword this one does not has to load without it.
    @Test
    func storedRecipesLoadAcrossAVocabularyChange() throws {
        let tagged = Recipe(
            title: "Stored",
            source: .tiktok,
            originalURL: URL(string: "https://example.com/stored")!,
            servings: 2,
            diets: [.vegan],
            keywords: [.onePot],
            keywordProposals: ["lemony"]
        )

        let encoded = try JSONEncoder().encode(tagged)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["keywords"] = ["onePot", "tagFromALaterRelease"]
        let widened = try JSONDecoder().decode(
            Recipe.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        #expect(widened.keywords == [.onePot])
        #expect(widened.diets == [.vegan])
        #expect(widened.keywordProposals == ["lemony"])

        object["diets"] = nil
        object["cuisines"] = nil
        object["keywords"] = nil
        object["keywordProposals"] = nil
        let untagged = try JSONDecoder().decode(
            Recipe.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )

        #expect(untagged.diets.isEmpty)
        #expect(untagged.cuisines.isEmpty)
        #expect(untagged.keywords.isEmpty)
        #expect(untagged.keywordProposals.isEmpty)
    }

    @Test
    func recipeNeedingReviewCannotStartCooking() {
        let recipe = Recipe(
            title: "Partial recipe",
            source: .tiktok,
            originalURL: URL(string: "https://example.com/partial")!,
            servings: 1,
            ingredients: [
                Ingredient(name: "Potato", orderIndex: 0),
            ],
            steps: [
                RecipeStep(orderIndex: 0, instruction: "Cook the potato."),
            ],
            reviewStatus: .needsReview
        )

        #expect(recipe.cookingReadiness == .needsReview)
        #expect(!recipe.canStartCooking)
    }

    @Test
    func recipeRequiresIngredientsAndMethodToStartCooking() {
        let empty = Recipe(
            title: "Empty recipe",
            source: .other,
            originalURL: URL(string: "https://example.com/empty")!,
            servings: 1
        )

        #expect(empty.cookingReadiness == .missingIngredients)
        #expect(!empty.canStartCooking)
    }

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

    @Test
    func cookingHistoryIsOptionalAndMutable() {
        let cookedAt = Date(timeIntervalSince1970: 500)
        var recipe = Recipe(
            title: "Lemon Orzo",
            source: .instagram,
            originalURL: URL(string: "https://example.com/orzo")!,
            servings: 4
        )

        #expect(recipe.lastCookedAt == nil)

        recipe.lastCookedAt = cookedAt

        #expect(recipe.lastCookedAt == cookedAt)
    }
}
