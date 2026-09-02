import Foundation
import Testing
@testable import LadleCore

/// The time a recipe can honestly show. Creators state a cook time far more
/// often than a total, so the rule has to fall back through what is there
/// rather than read `totalMinutes` and give up.
@Suite("Recipe time")
struct RecipeTimeTests {
    @Test
    func statedTotalWins() {
        let recipe = makeRecipe(preparation: 10, cooking: 20, total: 25)

        #expect(recipe.displayedTime?.minutes == 25)
        #expect(recipe.displayedTime?.label == "Total time")
    }

    @Test
    func statedPrepAndCookMakeATotal() {
        let recipe = makeRecipe(preparation: 10, cooking: 20, total: nil)

        #expect(recipe.displayedTime?.minutes == 30)
        #expect(recipe.displayedTime?.label == "Total time")
    }

    @Test
    func cookAloneShowsUnderItsOwnLabel() {
        let recipe = makeRecipe(preparation: nil, cooking: 35, total: nil)

        #expect(recipe.displayedTime?.minutes == 35)
        #expect(recipe.displayedTime?.label == "Cook time")
    }

    @Test
    func prepAloneShowsUnderItsOwnLabel() {
        let recipe = makeRecipe(preparation: 15, cooking: nil, total: nil)

        #expect(recipe.displayedTime?.minutes == 15)
        #expect(recipe.displayedTime?.label == "Prep time")
    }

    @Test
    func noStatedTimeShowsNothing() {
        let recipe = makeRecipe(preparation: nil, cooking: nil, total: nil)

        #expect(recipe.displayedTime == nil)
    }

    @Test
    func aTotalMinutesUncertaintyMarksTheTimeEstimated() {
        let recipe = makeRecipe(
            preparation: nil,
            cooking: nil,
            total: 45,
            uncertainties: [
                FieldUncertainty(
                    field: "total_minutes",
                    reason: "Estimated from the method."
                ),
            ]
        )

        #expect(recipe.isTimeEstimated)
        #expect(recipe.displayedTime?.minutes == 45)
    }

    @Test
    func anotherFieldsUncertaintyLeavesTheTimeStated() {
        let recipe = makeRecipe(
            preparation: nil,
            cooking: nil,
            total: 45,
            uncertainties: [
                FieldUncertainty(field: "servings", reason: "Not stated."),
            ]
        )

        #expect(!recipe.isTimeEstimated)
    }

    private func makeRecipe(
        preparation: Int?,
        cooking: Int?,
        total: Int?,
        uncertainties: [FieldUncertainty] = []
    ) -> Recipe {
        Recipe(
            title: "Timed recipe",
            source: .tiktok,
            originalURL: URL(string: "https://example.com/timed")!,
            preparationMinutes: preparation,
            cookingMinutes: cooking,
            totalMinutes: total,
            servings: 2,
            uncertainties: uncertainties
        )
    }
}
