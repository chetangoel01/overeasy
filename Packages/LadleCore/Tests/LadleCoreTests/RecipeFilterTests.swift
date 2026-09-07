import Foundation
import Testing
@testable import LadleCore

@Suite("Recipe filter")
struct RecipeFilterTests {
    private func recipe(
        _ title: String,
        diets: [DietTag] = [],
        cuisines: [CuisineTag] = [],
        keywords: [RecipeKeyword] = [],
        ingredients: [String] = []
    ) -> Recipe {
        Recipe(
            title: title,
            source: .youtube,
            originalURL: URL(string: "https://example.com/\(title)")!,
            servings: 2,
            ingredients: ingredients.enumerated().map { index, name in
                Ingredient(name: name, orderIndex: index)
            },
            diets: diets,
            cuisines: cuisines,
            keywords: keywords
        )
    }

    @Test
    func anEmptyFilterKeepsEverythingIncludingUntaggedRecipes() {
        let library = [recipe("Untagged"), recipe("Tagged", diets: [.vegan])]

        #expect(RecipeFilter.none.apply(to: library).count == 2)
        #expect(RecipeFilter.none.isEmpty)
    }

    @Test
    func everyChosenDietMustHold() {
        let both = recipe("Both", diets: [.vegan, .glutenFree])
        let one = recipe("One", diets: [.vegan])
        let filter = RecipeFilter(diets: [.vegan, .glutenFree])

        #expect(filter.apply(to: [both, one]).map(\.title) == ["Both"])
        #expect(filter.hasDiet)
    }

    @Test
    func anyChosenCuisineOrKeywordIsEnough() {
        let italian = recipe("Italian", cuisines: [.italian])
        let korean = recipe("Korean", cuisines: [.korean])
        let french = recipe("French", cuisines: [.french])
        let filter = RecipeFilter(cuisines: [.italian, .korean])

        #expect(
            filter.apply(to: [italian, korean, french]).map(\.title)
                == ["Italian", "Korean"]
        )

        let quick = recipe("Quick", keywords: [.weeknight, .onePot])
        let baked = recipe("Baked", keywords: [.baking])
        let keywordFilter = RecipeFilter(keywords: [.onePot, .mealPrep])

        #expect(
            keywordFilter.apply(to: [quick, baked]).map(\.title) == ["Quick"]
        )
    }

    @Test
    func everyIngredientTermMustAppearAndMatchesPartOfAName() {
        let both = recipe(
            "Both",
            ingredients: ["Boneless chicken thighs", "Chickpea flour"]
        )
        let one = recipe("One", ingredients: ["Chicken stock"])
        let filter = RecipeFilter(ingredients: ["CHICKEN", "chickpea"])

        #expect(filter.apply(to: [both, one]).map(\.title) == ["Both"])
        // Case and surrounding words are folded away on the way in, so the
        // term a cook typed is the term that is matched.
        #expect(filter.ingredients == ["chicken", "chickpea"])
    }

    @Test
    func familiesCombineWithAnd() {
        let match = recipe(
            "Match",
            diets: [.vegetarian],
            cuisines: [.indian],
            ingredients: ["Paneer"]
        )
        let wrongCuisine = recipe(
            "Wrong cuisine",
            diets: [.vegetarian],
            cuisines: [.italian],
            ingredients: ["Paneer"]
        )
        let filter = RecipeFilter(
            diets: [.vegetarian],
            cuisines: [.indian],
            ingredients: ["paneer"]
        )

        #expect(
            filter.apply(to: [match, wrongCuisine]).map(\.title) == ["Match"]
        )
    }

    @Test
    func theIngredientListRefusesBlanksRepeatsAndAnEleventhTerm() {
        var filter = RecipeFilter()

        // The macro cannot call a mutating member, so each answer is taken
        // first and asserted after.
        let took = filter.addIngredient("  Chicken  ")
        let repeated = filter.addIngredient("chicken")
        let blank = filter.addIngredient("   ")
        #expect(took)
        #expect(!repeated)
        #expect(!blank)

        for index in 1..<RecipeFilter.maximumIngredientTerms {
            let added = filter.addIngredient("term\(index)")
            #expect(added)
        }
        let overflowed = filter.addIngredient("one too many")
        #expect(!overflowed)
        #expect(filter.ingredients.count == RecipeFilter.maximumIngredientTerms)

        let long = String(
            repeating: "a",
            count: RecipeFilter.maximumIngredientTermLength + 20
        )
        var short = RecipeFilter()
        short.addIngredient(long)
        #expect(
            short.ingredients.first?.count
                == RecipeFilter.maximumIngredientTermLength
        )

        filter.removeIngredient("chicken")
        #expect(!filter.ingredients.contains("chicken"))
    }

    @Test
    func clearingBrowsingFiltersLeavesTheDietWhereItIs() {
        var filter = RecipeFilter(
            diets: [.pescatarian],
            cuisines: [.japanese],
            keywords: [.soup],
            ingredients: ["miso"]
        )

        filter.clearBrowsingFilters()

        #expect(filter.diets == [.pescatarian])
        #expect(filter.cuisines.isEmpty)
        #expect(filter.keywords.isEmpty)
        #expect(filter.ingredients.isEmpty)

        filter.clear()
        #expect(filter.isEmpty)
    }

    @Test
    func selectedTagsReadBackInVocabularyOrder() {
        let filter = RecipeFilter(
            diets: [.dairyFree, .vegan],
            cuisines: [.westAfrican, .american],
            keywords: [.pasta, .onePot]
        )

        #expect(filter.orderedDiets == [.vegan, .dairyFree])
        #expect(filter.orderedCuisines == [.american, .westAfrican])
        #expect(filter.orderedKeywords == [.onePot, .pasta])
    }
}
