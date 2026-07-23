import Foundation

public struct Nutrient: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let amount: Decimal
    public let unit: String

    public init(
        id: UUID = UUID(),
        name: String,
        amount: Decimal,
        unit: String
    ) {
        self.id = id
        self.name = name
        self.amount = amount
        self.unit = unit
    }
}

public struct Nutrition: Codable, Hashable, Sendable {
    public let calories: Decimal?
    public let proteinGrams: Decimal?
    public let carbohydrateGrams: Decimal?
    public let fatGrams: Decimal?
    public let saturatedFatGrams: Decimal?
    public let fiberGrams: Decimal?
    public let sugarGrams: Decimal?
    public let sodiumMilligrams: Decimal?
    public let otherNutrients: [Nutrient]
    public let servingBasis: Decimal
    public let isEstimated: Bool

    public init(
        calories: Decimal? = nil,
        proteinGrams: Decimal? = nil,
        carbohydrateGrams: Decimal? = nil,
        fatGrams: Decimal? = nil,
        saturatedFatGrams: Decimal? = nil,
        fiberGrams: Decimal? = nil,
        sugarGrams: Decimal? = nil,
        sodiumMilligrams: Decimal? = nil,
        otherNutrients: [Nutrient] = [],
        servingBasis: Decimal,
        isEstimated: Bool
    ) {
        self.calories = calories
        self.proteinGrams = proteinGrams
        self.carbohydrateGrams = carbohydrateGrams
        self.fatGrams = fatGrams
        self.saturatedFatGrams = saturatedFatGrams
        self.fiberGrams = fiberGrams
        self.sugarGrams = sugarGrams
        self.sodiumMilligrams = sodiumMilligrams
        self.otherNutrients = otherNutrients
        self.servingBasis = servingBasis
        self.isEstimated = isEstimated
    }
}
