import Foundation
import Testing
@testable import LadleCore

@Suite("Recipe query")
struct RecipeQueryTests {
    @Test
    func searchMatchesTitleAndCreatorCaseInsensitively() {
        let recipes = [
            recipe(title: "One-Pot Lemon Orzo", creator: "Mia Cooks"),
            recipe(title: "Garlic Butter Udon", creator: "Noodle House"),
        ]

        let titleMatches = RecipeQuery(searchText: "ORZO").apply(to: recipes)
        let creatorMatches = RecipeQuery(searchText: "mia").apply(to: recipes)

        #expect(titleMatches.map(\.title) == ["One-Pot Lemon Orzo"])
        #expect(creatorMatches.map(\.title) == ["One-Pot Lemon Orzo"])
    }

    @Test
    func filtersCompose() {
        let recipes = [
            recipe(
                title: "Quick Favorite",
                minutes: 20,
                calories: 400,
                isFavorite: true
            ),
            recipe(
                title: "Quick Rich",
                minutes: 20,
                calories: 700,
                isFavorite: true
            ),
            recipe(
                title: "Slow Favorite",
                minutes: 80,
                calories: 400,
                isFavorite: true
            ),
            recipe(
                title: "Quick Not Favorite",
                minutes: 20,
                calories: 400,
                isFavorite: false
            ),
        ]
        let query = RecipeQuery(
            favoritesOnly: true,
            maximumTotalMinutes: 45,
            maximumCalories: 500
        )

        #expect(query.apply(to: recipes).map(\.title) == ["Quick Favorite"])
    }

    @Test(
        arguments: [
            (RecipeSort.recentlyAdded, ["Newest", "Middle", "Oldest"]),
            (RecipeSort.cookingTime, ["Newest", "Oldest", "Middle"]),
            (RecipeSort.calories, ["Middle", "Oldest", "Newest"]),
            (RecipeSort.alphabetical, ["Middle", "Newest", "Oldest"]),
        ]
    )
    func sortingIsDeterministic(
        sort: RecipeSort,
        expectedTitles: [String]
    ) {
        let recipes = [
            recipe(
                title: "Oldest",
                minutes: 30,
                calories: 500,
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            recipe(
                title: "Middle",
                minutes: 40,
                calories: 300,
                createdAt: Date(timeIntervalSince1970: 200)
            ),
            recipe(
                title: "Newest",
                minutes: 20,
                calories: 700,
                createdAt: Date(timeIntervalSince1970: 300)
            ),
        ]

        let titles = RecipeQuery(sort: sort).apply(to: recipes).map(\.title)

        #expect(titles == expectedTitles)
    }

    private func recipe(
        title: String,
        creator: String? = nil,
        minutes: Int = 30,
        calories: Decimal = 500,
        isFavorite: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 100)
    ) -> Recipe {
        Recipe(
            title: title,
            creatorName: creator,
            source: .other,
            originalURL: URL(string: "https://example.com/\(title)")!,
            totalMinutes: minutes,
            servings: 2,
            nutrition: Nutrition(
                calories: calories,
                servingBasis: 1,
                isEstimated: true
            ),
            isFavorite: isFavorite,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}
