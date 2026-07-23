import Foundation
import Testing
@testable import LadleCore

@Suite("Nutrition scaling")
struct NutritionTests {
    @Test
    func scalesEveryAvailableNutrientToConsumedServings() {
        let nutrition = Nutrition(
            calories: 500,
            proteinGrams: 20,
            carbohydrateGrams: 40,
            fatGrams: 25,
            saturatedFatGrams: 8,
            fiberGrams: 5,
            sugarGrams: 6,
            sodiumMilligrams: 700,
            otherNutrients: [
                Nutrient(name: "Potassium", amount: 300, unit: "mg"),
            ],
            servingBasis: 1,
            isEstimated: true
        )

        let scaled = nutrition.scaled(toServings: 1.5)

        #expect(scaled.calories == 750)
        #expect(scaled.proteinGrams == 30)
        #expect(scaled.carbohydrateGrams == 60)
        #expect(scaled.fatGrams == 37.5)
        #expect(scaled.saturatedFatGrams == 12)
        #expect(scaled.fiberGrams == 7.5)
        #expect(scaled.sugarGrams == 9)
        #expect(scaled.sodiumMilligrams == 1_050)
        #expect(scaled.otherNutrients.first?.amount == 450)
        #expect(scaled.servingBasis == 1.5)
        #expect(scaled.isEstimated)
    }

    @Test
    func absentValuesRemainAbsentWhenScaled() {
        let nutrition = Nutrition(
            calories: 500,
            servingBasis: 1,
            isEstimated: true
        )

        let scaled = nutrition.scaled(toServings: 2)

        #expect(scaled.proteinGrams == nil)
        #expect(scaled.sodiumMilligrams == nil)
    }
}
