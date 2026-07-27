import Foundation

/// Client-visible limits mirrored by the backend `RecipeDTO` contract.
public enum RecipeContractLimits {
    public static let titleCharacters = 300
    public static let descriptionCharacters = 10_000
    public static let creatorCharacters = 200
    public static let quantityCharacters = 100
    public static let unitCharacters = 50
    public static let ingredientNameCharacters = 300
    public static let preparationCharacters = 500
    public static let instructionCharacters = 5_000

    public static let ingredients = 200
    public static let steps = 200
    public static let maximumMinutes = 43_200
    public static let maximumServings = Decimal(10_000)
    public static let maximumDecimal = Decimal(1_000_000)
}
