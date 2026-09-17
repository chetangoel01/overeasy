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
    /// Whether ingredients were left out of these totals.
    ///
    /// Distinct from `isEstimated`, which every calculated panel is: this
    /// one is also *incomplete*. The pipeline skips an ingredient no food
    /// record describes rather than voiding the whole recipe, so the number
    /// is honest about what it counted and short by what it could not.
    /// Which ingredients, and why, travel separately as uncertainties.
    public let approximate: Bool

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
        isEstimated: Bool,
        approximate: Bool = false
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
        self.approximate = approximate
    }

    /// Hand-written only for `approximate`, which is absent from every
    /// recipe encoded into the local store before the field existed and
    /// from anything an older server sends. Absent means complete.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        calories = try container.decodeIfPresent(
            Decimal.self,
            forKey: .calories
        )
        proteinGrams = try container.decodeIfPresent(
            Decimal.self,
            forKey: .proteinGrams
        )
        carbohydrateGrams = try container.decodeIfPresent(
            Decimal.self,
            forKey: .carbohydrateGrams
        )
        fatGrams = try container.decodeIfPresent(Decimal.self, forKey: .fatGrams)
        saturatedFatGrams = try container.decodeIfPresent(
            Decimal.self,
            forKey: .saturatedFatGrams
        )
        fiberGrams = try container.decodeIfPresent(
            Decimal.self,
            forKey: .fiberGrams
        )
        sugarGrams = try container.decodeIfPresent(
            Decimal.self,
            forKey: .sugarGrams
        )
        sodiumMilligrams = try container.decodeIfPresent(
            Decimal.self,
            forKey: .sodiumMilligrams
        )
        otherNutrients = try container.decode(
            [Nutrient].self,
            forKey: .otherNutrients
        )
        servingBasis = try container.decode(Decimal.self, forKey: .servingBasis)
        isEstimated = try container.decode(Bool.self, forKey: .isEstimated)
        approximate = try container.decodeIfPresent(
            Bool.self,
            forKey: .approximate
        ) ?? false
    }

    public func scaled(toServings servings: Decimal) -> Self {
        let multiplier = servings / servingBasis
        return Self(
            calories: calories.map { $0 * multiplier },
            proteinGrams: proteinGrams.map { $0 * multiplier },
            carbohydrateGrams: carbohydrateGrams.map { $0 * multiplier },
            fatGrams: fatGrams.map { $0 * multiplier },
            saturatedFatGrams: saturatedFatGrams.map { $0 * multiplier },
            fiberGrams: fiberGrams.map { $0 * multiplier },
            sugarGrams: sugarGrams.map { $0 * multiplier },
            sodiumMilligrams: sodiumMilligrams.map { $0 * multiplier },
            otherNutrients: otherNutrients.map {
                Nutrient(
                    id: $0.id,
                    name: $0.name,
                    amount: $0.amount * multiplier,
                    unit: $0.unit
                )
            },
            servingBasis: servings,
            isEstimated: isEstimated,
            approximate: approximate
        )
    }

    /// Where the calories come from, by the usual 4, 4 and 9 kcal a gram.
    ///
    /// Nil unless all three macros are known and add up to something: a
    /// missing gram count is not zero, and nothing has no shares. The sum
    /// is its own figure and is never reconciled with `calories` — fibre,
    /// alcohol and rounding on the source panel all keep the two apart.
    public var macroCalories: MacroCalories? {
        guard let proteinGrams, let carbohydrateGrams, let fatGrams,
              min(proteinGrams, carbohydrateGrams, fatGrams) >= 0
        else { return nil }
        let calories = [proteinGrams * 4, carbohydrateGrams * 4, fatGrams * 9]
        let total = calories.reduce(0, +)
        guard total > 0 else { return nil }

        // Largest remainder: rounding each share alone can print 101%.
        let exact = calories.map { $0 * 100 / total }
        let floors = exact.map { share in
            var share = share, floor = Decimal()
            NSDecimalRound(&floor, &share, 0, .down)
            return floor
        }
        var percents = floors.map { NSDecimalNumber(decimal: $0).intValue }
        let byRemainder = exact.indices.sorted {
            let (left, right) = (exact[$0] - floors[$0], exact[$1] - floors[$1])
            return left == right ? $0 < $1 : left > right
        }
        for index in byRemainder.prefix(100 - percents.reduce(0, +)) {
            percents[index] += 1
        }
        return MacroCalories(
            protein: .init(calories: calories[0], percent: percents[0]),
            carbohydrate: .init(calories: calories[1], percent: percents[1]),
            fat: .init(calories: calories[2], percent: percents[2])
        )
    }
}

public struct MacroCalories: Hashable, Sendable {
    public struct Share: Hashable, Sendable {
        public let calories: Decimal
        /// Whole-percent share of `total`; the three add to exactly 100.
        public let percent: Int
    }

    public let protein: Share
    public let carbohydrate: Share
    public let fat: Share

    public var total: Decimal {
        protein.calories + carbohydrate.calories + fat.calories
    }
}
