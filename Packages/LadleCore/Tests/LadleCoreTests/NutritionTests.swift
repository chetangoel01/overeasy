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

    @Test
    func scalingCarriesTheApproximateMarker() {
        // Every figure the app prints goes through `perServing`, which is a
        // freshly constructed value: a marker the scale drops is a marker
        // no screen ever sees.
        let nutrition = Nutrition(
            calories: 500,
            servingBasis: 4,
            isEstimated: true,
            approximate: true
        )

        #expect(nutrition.scaled(toServings: 1).approximate)
    }

    @Test
    func anOlderRecipeWithoutTheKeyDecodesAsComplete() throws {
        // Recipes already in the local store were encoded before the field
        // existed, and an older server never sends it.
        let payload = Data(
            """
            {
              "otherNutrients": [],
              "calories": 500,
              "servingBasis": 1,
              "isEstimated": true
            }
            """.utf8
        )

        let nutrition = try JSONDecoder().decode(Nutrition.self, from: payload)

        #expect(nutrition.approximate == false)
    }

    @Test
    func theApproximateMarkerSurvivesALocalRoundTrip() throws {
        let nutrition = Nutrition(
            calories: 500,
            servingBasis: 1,
            isEstimated: true,
            approximate: true
        )

        let restored = try JSONDecoder().decode(
            Nutrition.self,
            from: JSONEncoder().encode(nutrition)
        )

        #expect(restored.approximate)
    }
}

@Suite("Macro calories")
struct MacroCaloriesTests {
    @Test
    func countsFourFourAndNineCaloriesAGram() throws {
        let macros = try #require(
            nutrition(protein: 38, carbohydrate: 35, fat: 42).macroCalories
        )

        #expect(macros.protein.calories == 152)
        #expect(macros.carbohydrate.calories == 140)
        #expect(macros.fat.calories == 378)
        #expect(macros.total == 670)
    }

    @Test
    func wholePercentSharesAddToOneHundred() throws {
        // A gram of each is 4, 4 and 9 of 17 kcal — 23.5, 23.5 and 52.9
        // percent, which rounded one at a time read 24 + 24 + 53 = 101.
        let macros = try #require(
            nutrition(protein: 1, carbohydrate: 1, fat: 1).macroCalories
        )

        #expect(macros.protein.percent == 24)
        #expect(macros.carbohydrate.percent == 23)
        #expect(macros.fat.percent == 53)
    }

    @Test
    func aMissingMacroLeavesNoBreakdown() {
        let nutrition = nutrition(protein: 38, carbohydrate: nil, fat: 42)

        #expect(nutrition.macroCalories == nil)
    }

    @Test
    func nothingToShareOutLeavesNoBreakdown() {
        #expect(
            nutrition(protein: 0, carbohydrate: 0, fat: 0).macroCalories == nil
        )
        // A negative gram count is bad data, not a share of anything.
        #expect(
            nutrition(protein: -5, carbohydrate: 50, fat: 10).macroCalories
                == nil
        )
    }

    private func nutrition(
        protein: Decimal?,
        carbohydrate: Decimal?,
        fat: Decimal?
    ) -> Nutrition {
        Nutrition(
            proteinGrams: protein,
            carbohydrateGrams: carbohydrate,
            fatGrams: fat,
            servingBasis: 1,
            isEstimated: true
        )
    }
}
