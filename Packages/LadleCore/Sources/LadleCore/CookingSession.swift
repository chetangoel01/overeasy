import Foundation

public enum CookingMode: String, Codable, Hashable, Sendable {
    case fullRecipe
    case focus
}

public struct CookingSession: Codable, Hashable, Sendable {
    public let stepIDs: [UUID]
    public private(set) var currentStepIndex: Int
    public private(set) var mode: CookingMode
    public private(set) var completedStepIDs: Set<UUID>
    public private(set) var completedIngredientIDs: Set<UUID>

    public init(
        stepIDs: [UUID],
        currentStepIndex: Int = 0,
        mode: CookingMode = .fullRecipe,
        completedStepIDs: Set<UUID> = [],
        completedIngredientIDs: Set<UUID> = []
    ) {
        self.stepIDs = stepIDs
        self.currentStepIndex = min(
            max(currentStepIndex, 0),
            max(stepIDs.count - 1, 0)
        )
        self.mode = mode
        self.completedStepIDs = completedStepIDs
        self.completedIngredientIDs = completedIngredientIDs
    }

    public var currentStepID: UUID? {
        stepIDs.indices.contains(currentStepIndex)
            ? stepIDs[currentStepIndex]
            : nil
    }

    public mutating func moveNext() {
        guard currentStepIndex < stepIDs.count - 1 else {
            return
        }
        currentStepIndex += 1
    }

    public mutating func movePrevious() {
        guard currentStepIndex > 0 else {
            return
        }
        currentStepIndex -= 1
    }

    public mutating func setMode(_ mode: CookingMode) {
        self.mode = mode
    }

    public mutating func toggleCompletedStep(_ stepID: UUID) {
        if completedStepIDs.contains(stepID) {
            completedStepIDs.remove(stepID)
        } else {
            completedStepIDs.insert(stepID)
        }
    }

    public mutating func toggleCompletedIngredient(_ ingredientID: UUID) {
        if completedIngredientIDs.contains(ingredientID) {
            completedIngredientIDs.remove(ingredientID)
        } else {
            completedIngredientIDs.insert(ingredientID)
        }
    }
}
