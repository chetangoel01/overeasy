import Foundation
import LadleCore
import Observation

enum RecipeDraftValidationIssue: Hashable {
    case titleRequired
    case servingsMustBePositive
    case preparationMinutesInvalid
    case cookingMinutesInvalid
    case ingredientNameRequired(UUID)
    case stepInstructionRequired(UUID)
    case nutritionValueInvalid(String)
}

enum RecipeEditorState: Equatable {
    case editing
    case saved(Recipe)
    case persistenceFailed
}

@MainActor
@Observable
final class RecipeEditorViewModel: Identifiable {
    var draft: RecipeDraft
    private(set) var validationIssues:
        Set<RecipeDraftValidationIssue> = []
    private(set) var state: RecipeEditorState = .editing

    @ObservationIgnored
    private let repository: RecipeRepository

    @ObservationIgnored
    private let now: () -> Date

    private var originalRecipe: Recipe

    init(
        recipe: Recipe,
        repository: RecipeRepository,
        now: @escaping () -> Date = Date.init
    ) {
        originalRecipe = recipe
        draft = RecipeDraft(recipe: recipe)
        self.repository = repository
        self.now = now
    }

    var hasChanges: Bool {
        draft != RecipeDraft(recipe: originalRecipe)
    }

    func addIngredient() {
        draft.ingredients.append(.init())
    }

    func removeIngredient(id: UUID) {
        draft.ingredients.removeAll { $0.id == id }
        for index in draft.steps.indices {
            draft.steps[index].ingredientIDs.removeAll { $0 == id }
        }
    }

    func moveIngredient(from source: Int, to destination: Int) {
        move(in: &draft.ingredients, from: source, to: destination)
    }

    func addStep() {
        draft.steps.append(.init())
    }

    func removeStep(id: UUID) {
        draft.steps.removeAll { $0.id == id }
    }

    func moveStep(from source: Int, to destination: Int) {
        move(in: &draft.steps, from: source, to: destination)
    }

    @discardableResult
    func save() -> Recipe? {
        validationIssues = validate()
        guard validationIssues.isEmpty else {
            state = .editing
            return nil
        }

        let recipe = draft.recipe(updatedAt: now())
        do {
            try repository.save(recipe)
            originalRecipe = recipe
            draft = RecipeDraft(recipe: recipe)
            state = .saved(recipe)
            return recipe
        } catch {
            state = .persistenceFailed
            return nil
        }
    }

    func discardChanges() {
        draft = RecipeDraft(recipe: originalRecipe)
        validationIssues = []
        state = .editing
    }

    func hasIssue(_ issue: RecipeDraftValidationIssue) -> Bool {
        validationIssues.contains(issue)
    }

    private func validate() -> Set<RecipeDraftValidationIssue> {
        var issues: Set<RecipeDraftValidationIssue> = []
        if normalized(draft.title) == nil {
            issues.insert(.titleRequired)
        }
        if let servings = decimal(draft.servings), servings > 0 {
            // Valid.
        } else {
            issues.insert(.servingsMustBePositive)
        }
        if !isValidOptionalInteger(draft.preparationMinutes) {
            issues.insert(.preparationMinutesInvalid)
        }
        if !isValidOptionalInteger(draft.cookingMinutes) {
            issues.insert(.cookingMinutesInvalid)
        }
        for ingredient in draft.ingredients
        where normalized(ingredient.name) == nil {
            issues.insert(.ingredientNameRequired(ingredient.id))
        }
        for step in draft.steps
        where normalized(step.instruction) == nil {
            issues.insert(.stepInstructionRequired(step.id))
        }

        if draft.nutrition.isIncluded {
            let values = [
                ("Calories", draft.nutrition.calories),
                ("Protein", draft.nutrition.proteinGrams),
                ("Carbohydrates", draft.nutrition.carbohydrateGrams),
                ("Fat", draft.nutrition.fatGrams),
                ("Saturated fat", draft.nutrition.saturatedFatGrams),
                ("Fiber", draft.nutrition.fiberGrams),
                ("Sugar", draft.nutrition.sugarGrams),
                ("Sodium", draft.nutrition.sodiumMilligrams),
            ]
            for (name, text) in values
            where !isValidOptionalDecimal(text) {
                issues.insert(.nutritionValueInvalid(name))
            }
            if let basis = decimal(draft.nutrition.servingBasis),
               basis > 0 {
                // Valid.
            } else {
                issues.insert(.nutritionValueInvalid("Serving basis"))
            }
        }
        return issues
    }

    private func move<Element>(
        in values: inout [Element],
        from source: Int,
        to destination: Int
    ) {
        guard values.indices.contains(source),
              destination >= 0,
              destination < values.count,
              source != destination else {
            return
        }
        let value = values.remove(at: source)
        values.insert(value, at: destination)
    }

    private func isValidOptionalInteger(_ text: String) -> Bool {
        guard let value = normalized(text) else {
            return true
        }
        return Int(value).map { $0 >= 0 } ?? false
    }

    private func isValidOptionalDecimal(_ text: String) -> Bool {
        guard let value = normalized(text) else {
            return true
        }
        return decimal(value).map { $0 >= 0 } ?? false
    }

    private func decimal(_ text: String) -> Decimal? {
        normalized(text).flatMap {
            Decimal(
                string: $0,
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
    }

    private func normalized(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
