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
