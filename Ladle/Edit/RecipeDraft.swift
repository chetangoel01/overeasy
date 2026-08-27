import Foundation
import LadleCore

/// Parses the numbers typed into the editor's fields.
///
/// Those fields use a `.decimalPad`, which renders the *current locale's*
/// decimal separator and digits. Parsing them against a fixed POSIX locale
/// read "1,5" as 1 — a recipe silently saved and synced with the wrong
/// yield, and every per-serving nutrition figure derived from it wrong too.
/// `NumberFormatter` uses the locale's own separator and digits, and returns
/// nil for anything it cannot parse whole, so trailing junk is rejected by
/// validation instead of being truncated into a plausible number.
enum EditorNumber {
    static func decimal(_ text: String, locale: Locale) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.generatesDecimalNumbers = true
        guard
            let number = formatter.number(from: trimmed) as? NSDecimalNumber
        else {
            return nil
        }
        return number.decimalValue
    }
}

struct RecipeDraft: Equatable {
    struct IngredientDraft: Equatable, Identifiable {
        let id: UUID
        var quantityText: String
        var unit: String
        var name: String
        var preparation: String
        var uncertainty: FieldUncertainty?

        /// The imported quantity pair. The machine-readable amount came
        /// from the importer's parsing of exactly this text, so it is
        /// only trustworthy while `quantityText` still reads that way.
        private let importedQuantityText: String
        private let importedNormalizedQuantity: Decimal?

        init(_ ingredient: Ingredient) {
            id = ingredient.id
            quantityText = ingredient.quantityText ?? ""
            unit = ingredient.unit ?? ""
            name = ingredient.name
            preparation = ingredient.preparation ?? ""
            uncertainty = ingredient.uncertainty
            importedQuantityText = ingredient.quantityText ?? ""
            importedNormalizedQuantity = ingredient.normalizedQuantity
        }

        init(id: UUID = UUID()) {
            self.id = id
            quantityText = ""
            unit = ""
            name = ""
            preparation = ""
            uncertainty = nil
            importedQuantityText = ""
            importedNormalizedQuantity = nil
        }

        /// The machine-readable amount to persist alongside
        /// `quantityText`. An edited text re-derives it (nil when the
        /// editor cannot parse it whole), so the pair can never
        /// disagree; the richer imported value survives while the text
        /// is unedited — or an edit is reverted.
        func normalizedQuantity(locale: Locale) -> Decimal? {
            quantityText == importedQuantityText
                ? importedNormalizedQuantity
                : EditorNumber.decimal(quantityText, locale: locale)
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

    func recipe(updatedAt: Date, locale: Locale = .current) -> Recipe {
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
            servings: decimal(from: servings, locale: locale) ?? 1,
            ingredients: ingredients.enumerated().map { index, draft in
                Ingredient(
                    id: draft.id,
                    quantityText: normalized(draft.quantityText),
                    normalizedQuantity: draft.normalizedQuantity(
                        locale: locale
                    ),
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
            nutrition: makeNutrition(locale: locale),
            isFavorite: isFavorite,
            reviewStatus: reviewStatus,
            uncertainties: uncertainties,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func makeNutrition(locale: Locale) -> Nutrition? {
        guard nutrition.isIncluded else {
            return nil
        }
        return Nutrition(
            calories: decimal(from: nutrition.calories, locale: locale),
            proteinGrams: decimal(
                from: nutrition.proteinGrams,
                locale: locale
            ),
            carbohydrateGrams: decimal(
                from: nutrition.carbohydrateGrams,
                locale: locale
            ),
            fatGrams: decimal(from: nutrition.fatGrams, locale: locale),
            saturatedFatGrams: decimal(
                from: nutrition.saturatedFatGrams,
                locale: locale
            ),
            fiberGrams: decimal(from: nutrition.fiberGrams, locale: locale),
            sugarGrams: decimal(from: nutrition.sugarGrams, locale: locale),
            sodiumMilligrams: decimal(
                from: nutrition.sodiumMilligrams,
                locale: locale
            ),
            otherNutrients: nutrition.otherNutrients,
            servingBasis: decimal(
                from: nutrition.servingBasis,
                locale: locale
            ) ?? 1,
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

    private func decimal(from text: String, locale: Locale) -> Decimal? {
        EditorNumber.decimal(text, locale: locale)
    }
}
