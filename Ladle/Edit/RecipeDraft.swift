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

    /// A stored amount written the way the field it goes into is read.
    ///
    /// `NSDecimalNumber.stringValue` is not locale-aware and would put a
    /// French cook's "0,5" on screen as "0.5", which their own decimal pad
    /// then cannot reproduce — the next save would drop the amount. Six
    /// fraction digits is the scale the backend stores.
    static func text(_ value: Decimal, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        return formatter.string(from: NSDecimalNumber(decimal: value))
            ?? NSDecimalNumber(decimal: value).stringValue
    }
}

private extension String {
    /// Trimmed, or nothing at all when that leaves it empty.
    var editorNormalized: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

struct RecipeDraft: Equatable {
    /// An ingredient as the editor holds it: a number, a unit, a name.
    ///
    /// There is no field for the creator's phrase. It is carried untouched
    /// so a saved recipe keeps the note it arrived with, but nothing reads
    /// it back — a row is rendered from the quantity and the unit, and a
    /// cook editing the phrase would be editing something invisible.
    struct IngredientDraft: Equatable, Identifiable {
        let id: UUID
        /// A number and nothing else, written in the editor's locale.
        var quantity: String
        var unit: String
        var name: String
        var preparation: String
        /// The ingredient has no amount to measure. Both fields above are
        /// disabled while it is on, and saving clears them.
        var isToTaste: Bool
        var uncertainty: FieldUncertainty?

        /// What the creator said, carried and never edited.
        private let quantityText: String?

        init(_ ingredient: Ingredient, locale: Locale = .current) {
            id = ingredient.id
            // A row that reached the device without a quantity cannot be
            // rendered as one, so the editor opens on the truth about it
            // rather than blocking the save behind a number the cook was
            // never given.
            isToTaste = ingredient.isToTaste || ingredient.normalizedQuantity == nil
            quantity = ingredient.normalizedQuantity
                .map { EditorNumber.text($0, locale: locale) } ?? ""
            unit = ingredient.unit ?? ""
            name = ingredient.name
            preparation = ingredient.preparation ?? ""
            uncertainty = ingredient.uncertainty
            quantityText = ingredient.quantityText
        }

        init(id: UUID = UUID()) {
            self.id = id
            quantity = ""
            unit = ""
            name = ""
            preparation = ""
            isToTaste = false
            uncertainty = nil
            quantityText = nil
        }

        /// The amount to persist: nil when the ingredient has none, and nil
        /// when the editor cannot parse the field whole — which validation
        /// has already refused to save.
        func normalizedQuantity(locale: Locale) -> Decimal? {
            isToTaste ? nil : EditorNumber.decimal(quantity, locale: locale)
        }

        func ingredient(orderIndex: Int, locale: Locale) -> Ingredient {
            let amount = normalizedQuantity(locale: locale)
            return Ingredient(
                id: id,
                quantityText: quantityText,
                normalizedQuantity: amount,
                unit: isToTaste ? nil : unit.editorNormalized,
                name: name.editorNormalized ?? "",
                preparation: preparation.editorNormalized,
                isToTaste: isToTaste || amount == nil,
                orderIndex: orderIndex,
                uncertainty: uncertainty
            )
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
        /// Carried, never edited. The pipeline's record of what it could not
        /// count, which a cook fixing a typo in the calories has no way to
        /// answer and no business clearing.
        var approximate: Bool

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
            approximate = nutrition?.approximate ?? false
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
    /// Carried, never edited. The editor rebuilds the whole recipe from
    /// this draft, so a draft that dropped the tags would strip the local
    /// copy of them on every rename — the server is safe (a write sends
    /// null and it keeps what is stored), but the phone would be filtering
    /// on nothing until the next sync pull.
    let diets: [DietTag]
    let cuisines: [CuisineTag]
    let keywords: [RecipeKeyword]
    let keywordProposals: [String]

    init(recipe: Recipe, locale: Locale = .current) {
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
        ingredients = recipe.orderedIngredients.map {
            IngredientDraft($0, locale: locale)
        }
        steps = recipe.orderedSteps.map(StepDraft.init)
        nutrition = NutritionDraft(recipe.nutrition)
        diets = recipe.diets
        cuisines = recipe.cuisines
        keywords = recipe.keywords
        keywordProposals = recipe.keywordProposals
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
                draft.ingredient(orderIndex: index, locale: locale)
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
            diets: diets,
            cuisines: cuisines,
            keywords: keywords,
            keywordProposals: keywordProposals,
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
            isEstimated: nutrition.isEstimated,
            approximate: nutrition.approximate
        )
    }

    private func normalized(_ text: String) -> String? {
        text.editorNormalized
    }

    private func integer(from text: String) -> Int? {
        normalized(text).flatMap(Int.init)
    }

    private func decimal(from text: String, locale: Locale) -> Decimal? {
        EditorNumber.decimal(text, locale: locale)
    }
}
