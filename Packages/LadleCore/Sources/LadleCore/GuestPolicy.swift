import Foundation

public enum GuestSaveDecision: Equatable, Sendable {
    case allow
    case allowWithAccountPrompt
    case limitReached
}

public enum GuestPolicy {
    public static let recipeLimit = 10

    public static func decision(savedRecipeCount: Int) -> GuestSaveDecision {
        switch savedRecipeCount {
        case recipeLimit...:
            .limitReached
        case recipeLimit - 1:
            .allowWithAccountPrompt
        default:
            .allow
        }
    }

    public static func canOpenExistingRecipe(
        _ recipeID: UUID,
        savedRecipeIDs: Set<UUID>,
        savedRecipeCount: Int
    ) -> Bool {
        savedRecipeIDs.contains(recipeID)
    }
}
