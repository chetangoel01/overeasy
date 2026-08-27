import Foundation
import LadleCore
import Observation

enum RecipeDraftValidationIssue: Hashable {
    case titleRequired
    case titleTooLong
    case creatorNameTooLong
    case descriptionTooLong
    case servingsMustBePositive
    case preparationMinutesInvalid
    case cookingMinutesInvalid
    case totalMinutesInvalid
    case tooManyIngredients
    case tooManySteps
    case ingredientNameRequired(UUID)
    case ingredientFieldTooLong(UUID)
    case stepInstructionRequired(UUID)
    case stepInstructionTooLong(UUID)
    case nutritionValueInvalid(String)
}

enum RecipeEditorState: Equatable {
    case editing
    case saved(Recipe)
    case persistenceFailed
}

/// The editor's tab sections. The view model owns this so it can say which
/// section a rejected save should send the user to.
enum RecipeEditorSection: String, CaseIterable, Identifiable {
    case basics = "Basics"
    case media = "Media"
    case timing = "Timing"
    case ingredients = "Ingredients"
    case method = "Method"
    case nutrition = "Nutrition"

    var id: String { rawValue }

    /// The section whose fields own `issue`. Every issue the draft can raise
    /// belongs to exactly one section, so a rejected save can always name
    /// somewhere to look.
    static func owning(
        _ issue: RecipeDraftValidationIssue
    ) -> RecipeEditorSection {
        switch issue {
        case .titleRequired,
             .titleTooLong,
             .creatorNameTooLong,
             .descriptionTooLong:
            .basics
        case .servingsMustBePositive,
             .preparationMinutesInvalid,
             .cookingMinutesInvalid,
             .totalMinutesInvalid:
            .timing
        case .tooManyIngredients,
             .ingredientNameRequired,
             .ingredientFieldTooLong:
            .ingredients
        case .tooManySteps,
             .stepInstructionRequired,
             .stepInstructionTooLong:
            .method
        case .nutritionValueInvalid:
            .nutrition
        }
    }
}

/// A rejected save, described for the user: what is wrong, and where to look.
struct RecipeEditorValidationSummary: Equatable {
    let headline: String
    let detail: String
    let sections: [RecipeEditorSection]
}

@MainActor
@Observable
final class RecipeEditorViewModel: Identifiable {
    var draft: RecipeDraft
    private(set) var validationIssues:
        Set<RecipeDraftValidationIssue> = []
    private(set) var state: RecipeEditorState = .editing

    /// Sections holding at least one rejected field, in tab order.
    var sectionsNeedingAttention: [RecipeEditorSection] {
        let owning = Set(validationIssues.map(RecipeEditorSection.owning))
        return RecipeEditorSection.allCases.filter(owning.contains)
    }

    /// Non-nil once a save has been rejected. Each inline message renders
    /// inside its own field's section, so a save rejected for a field the
    /// user is not looking at needs a summary that travels with them —
    /// otherwise the Save tap reads as a dead button.
    var validationSummary: RecipeEditorValidationSummary? {
        let sections = sectionsNeedingAttention
        guard !sections.isEmpty else { return nil }
        let count = validationIssues.count
        return RecipeEditorValidationSummary(
            headline: count == 1
                ? "Can't save yet — one field needs attention"
                : "Can't save yet — \(count) fields need attention",
            detail: "Check \(sections.map(\.rawValue).formatted(.list(type: .and))).",
            sections: sections
        )
    }

    @ObservationIgnored
    private let repository: RecipeRepository

    @ObservationIgnored
    private let now: () -> Date
    private let locale: Locale

    @ObservationIgnored
    private let didSave:
        @MainActor @Sendable () async -> Void

    private var originalRecipe: Recipe

    init(
        recipe: Recipe,
        repository: RecipeRepository,
        now: @escaping () -> Date = Date.init,
        locale: Locale = .current,
        didSave:
            @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        originalRecipe = recipe
        draft = RecipeDraft(recipe: recipe)
        self.repository = repository
        self.now = now
        self.locale = locale
        self.didSave = didSave
    }

    var hasChanges: Bool {
        draft != RecipeDraft(recipe: originalRecipe)
    }

    func addIngredient() {
        guard draft.ingredients.count < RecipeContractLimits.ingredients else {
            return
        }
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
        guard draft.steps.count < RecipeContractLimits.steps else {
            return
        }
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

        let recipe = draft.recipe(updatedAt: now(), locale: locale)
        do {
            try repository.save(recipe)
            originalRecipe = recipe
            draft = RecipeDraft(recipe: recipe)
            state = .saved(recipe)
            Task {
                await didSave()
            }
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
        if exceeds(
            normalized(draft.title),
            RecipeContractLimits.titleCharacters
        ) {
            issues.insert(.titleTooLong)
        }
        if exceeds(
            normalized(draft.creatorName),
            RecipeContractLimits.creatorCharacters
        ) {
            issues.insert(.creatorNameTooLong)
        }
        if exceeds(
            normalized(draft.description),
            RecipeContractLimits.descriptionCharacters
        ) {
            issues.insert(.descriptionTooLong)
        }
        if let servings = decimal(draft.servings),
           servings > 0,
           servings <= RecipeContractLimits.maximumServings,
           hasValidScale(servings) {
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
        let preparation = integer(draft.preparationMinutes)
        let cooking = integer(draft.cookingMinutes)
        if preparation.map({ $0 > RecipeContractLimits.maximumMinutes }) == true
            || cooking.map({ $0 > RecipeContractLimits.maximumMinutes }) == true
            || (preparation ?? 0) + (cooking ?? 0)
            > RecipeContractLimits.maximumMinutes {
            issues.insert(.totalMinutesInvalid)
        }
        if draft.ingredients.count > RecipeContractLimits.ingredients {
            issues.insert(.tooManyIngredients)
        }
        if draft.steps.count > RecipeContractLimits.steps {
            issues.insert(.tooManySteps)
        }
        for ingredient in draft.ingredients {
            if normalized(ingredient.name) == nil {
                issues.insert(.ingredientNameRequired(ingredient.id))
            }
            if exceeds(
                normalized(ingredient.quantityText),
                RecipeContractLimits.quantityCharacters
            ) || exceeds(
                normalized(ingredient.unit),
                RecipeContractLimits.unitCharacters
            ) || exceeds(
                normalized(ingredient.name),
                RecipeContractLimits.ingredientNameCharacters
            ) || exceeds(
                normalized(ingredient.preparation),
                RecipeContractLimits.preparationCharacters
            ) {
                issues.insert(.ingredientFieldTooLong(ingredient.id))
            }
        }
        for step in draft.steps {
            if normalized(step.instruction) == nil {
                issues.insert(.stepInstructionRequired(step.id))
            }
            if exceeds(
                normalized(step.instruction),
                RecipeContractLimits.instructionCharacters
            ) {
                issues.insert(.stepInstructionTooLong(step.id))
            }
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
               basis > 0,
               basis <= RecipeContractLimits.maximumDecimal,
               hasValidScale(basis) {
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
        return Int(value).map {
            $0 >= 0 && $0 <= RecipeContractLimits.maximumMinutes
        } ?? false
    }

    private func isValidOptionalDecimal(_ text: String) -> Bool {
        guard let value = normalized(text) else {
            return true
        }
        return decimal(value).map {
            $0 >= 0
                && $0 <= RecipeContractLimits.maximumDecimal
                && hasValidScale($0)
        } ?? false
    }

    private func integer(_ text: String) -> Int? {
        normalized(text).flatMap(Int.init)
    }

    private func decimal(_ text: String) -> Decimal? {
        EditorNumber.decimal(text, locale: locale)
    }

    private func normalized(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func exceeds(_ text: String?, _ maximum: Int) -> Bool {
        text.map { $0.unicodeScalars.count > maximum } ?? false
    }

    private func hasValidScale(_ value: Decimal) -> Bool {
        let text = NSDecimalNumber(decimal: value).stringValue
        let fractional = text.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).dropFirst().first
        return fractional.map { $0.count <= 6 } ?? true
    }
}
