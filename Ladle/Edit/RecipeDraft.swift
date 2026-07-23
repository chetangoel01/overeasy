import Foundation
import LadleCore

struct RecipeDraft: Equatable {
    struct IngredientDraft: Equatable, Identifiable {
        let id: UUID
        var quantityText: String
        var normalizedQuantity: Decimal?
        var unit: String
        var name: String
        var preparation: String
        var uncertainty: FieldUncertainty?

        init(_ ingredient: Ingredient) {
            id = ingredient.id
            quantityText = ingredient.quantityText ?? ""
            normalizedQuantity = ingredient.normalizedQuantity
            unit = ingredient.unit ?? ""
            name = ingredient.name
            preparation = ingredient.preparation ?? ""
            uncertainty = ingredient.uncertainty
        }

        init(id: UUID = UUID()) {
            self.id = id
            quantityText = ""
            normalizedQuantity = nil
            unit = ""
            name = ""
            preparation = ""
            uncertainty = nil
        }
    }

    struct StepDraft: Equatable, Identifiable {
        let id: UUID
        var instruction: String
        var ingredientIDs: [UUID]
        var timers: [DetectedTimer]
        var uncertainty: FieldUncertainty?

        init(_ step: RecipeStep) {
            id = step.id
            instruction = step.instruction
            ingredientIDs = step.ingredientIDs
            timers = step.timers
            uncertainty = step.uncertainty
        }

        init(id: UUID = UUID()) {
            self.id = id
            instruction = ""
            ingredientIDs = []
            timers = []
            uncertainty = nil
        }
    }

    struct NutritionDraft: Equatable {
        var isIncluded: Bool
        var calories: String
        var proteinGrams: String
        var carbohydrateGrams: String
        var fatGrams: String
        var saturatedFatGrams: String
        var fiberGrams: String
        var sugarGrams: String
        var sodiumMilligrams: String
        var otherNutrients: [Nutrient]
        var servingBasis: String
        var isEstimated: Bool

        init(_ nutrition: Nutrition?) {
            isIncluded = nutrition != nil
            calories = Self.text(nutrition?.calories)
            proteinGrams = Self.text(nutrition?.proteinGrams)
            carbohydrateGrams = Self.text(
                nutrition?.carbohydrateGrams
            )
            fatGrams = Self.text(nutrition?.fatGrams)
            saturatedFatGrams = Self.text(
                nutrition?.saturatedFatGrams
            )
            fiberGrams = Self.text(nutrition?.fiberGrams)
            sugarGrams = Self.text(nutrition?.sugarGrams)
            sodiumMilligrams = Self.text(
                nutrition?.sodiumMilligrams
            )
            otherNutrients = nutrition?.otherNutrients ?? []
            servingBasis = nutrition.map {
                Self.text($0.servingBasis)
            } ?? "1"
            isEstimated = nutrition?.isEstimated ?? true
        }

        private static func text(_ value: Decimal?) -> String {
            value.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        }
    }

    let id: UUID
    let source: RecipeSource
    let originalURL: URL
    var images: [RecipeImage]
    let isFavorite: Bool
    let reviewStatus: RecipeReviewStatus
    let uncertainties: [FieldUncertainty]
    let createdAt: Date

    var title: String
    var description: String
    var creatorName: String
    var preparationMinutes: String
    var cookingMinutes: String
    var servings: String
    var ingredients: [IngredientDraft]
    var steps: [StepDraft]
    var nutrition: NutritionDraft

    init(recipe: Recipe) {
        id = recipe.id
        source = recipe.source
        originalURL = recipe.originalURL
        images = recipe.images
        isFavorite = recipe.isFavorite
        reviewStatus = recipe.reviewStatus
        uncertainties = recipe.uncertainties
        createdAt = recipe.createdAt
        title = recipe.title
        description = recipe.description
        creatorName = recipe.creatorName ?? ""
        preparationMinutes = recipe.preparationMinutes.map(String.init) ?? ""
        cookingMinutes = recipe.cookingMinutes.map(String.init) ?? ""
        servings = NSDecimalNumber(decimal: recipe.servings).stringValue
        ingredients = recipe.orderedIngredients.map(IngredientDraft.init)
        steps = recipe.orderedSteps.map(StepDraft.init)
        nutrition = NutritionDraft(recipe.nutrition)
    }

    func recipe(updatedAt: Date) -> Recipe {
        let preparation = integer(from: preparationMinutes)
        let cooking = integer(from: cookingMinutes)
        let total = [preparation, cooking]
            .compactMap { $0 }
            .reduce(0, +)

        return Recipe(
            id: id,
            title: normalized(title) ?? "",
            description: normalized(description) ?? "",
            creatorName: normalized(creatorName),
            source: source,
            originalURL: originalURL,
            images: images,
            preparationMinutes: preparation,
            cookingMinutes: cooking,
            totalMinutes: preparation == nil && cooking == nil ? nil : total,
            servings: decimal(from: servings) ?? 1,
            ingredients: ingredients.enumerated().map { index, draft in
                Ingredient(
                    id: draft.id,
                    quantityText: normalized(draft.quantityText),
                    normalizedQuantity: draft.normalizedQuantity,
                    unit: normalized(draft.unit),
                    name: normalized(draft.name) ?? "",
                    preparation: normalized(draft.preparation),
                    orderIndex: index,
                    uncertainty: draft.uncertainty
                )
            },
            steps: steps.enumerated().map { index, draft in
                RecipeStep(
                    id: draft.id,
                    orderIndex: index,
                    instruction: normalized(draft.instruction) ?? "",
                    ingredientIDs: draft.ingredientIDs,
                    timers: draft.timers,
                    uncertainty: draft.uncertainty
                )
            },
            nutrition: makeNutrition(),
            isFavorite: isFavorite,
            reviewStatus: reviewStatus,
            uncertainties: uncertainties,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func makeNutrition() -> Nutrition? {
        guard nutrition.isIncluded else {
            return nil
        }
        return Nutrition(
            calories: decimal(from: nutrition.calories),
            proteinGrams: decimal(from: nutrition.proteinGrams),
            carbohydrateGrams: decimal(
                from: nutrition.carbohydrateGrams
            ),
            fatGrams: decimal(from: nutrition.fatGrams),
            saturatedFatGrams: decimal(
                from: nutrition.saturatedFatGrams
            ),
            fiberGrams: decimal(from: nutrition.fiberGrams),
            sugarGrams: decimal(from: nutrition.sugarGrams),
            sodiumMilligrams: decimal(
                from: nutrition.sodiumMilligrams
            ),
            otherNutrients: nutrition.otherNutrients,
            servingBasis: decimal(from: nutrition.servingBasis) ?? 1,
            isEstimated: nutrition.isEstimated
        )
    }

    private func normalized(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func integer(from text: String) -> Int? {
        normalized(text).flatMap(Int.init)
    }

    private func decimal(from text: String) -> Decimal? {
        normalized(text).flatMap {
            Decimal(
                string: $0,
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
    }
}
