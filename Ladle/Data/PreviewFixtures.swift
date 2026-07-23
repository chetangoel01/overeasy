import Foundation
import LadleCore

enum PreviewFixtures {
    private static let baseDate = Date(timeIntervalSince1970: 1_784_836_000)

    static let recipes: [Recipe] = [
        makeRecipe(
            id: "B54D0E5B-8B10-410F-ADE7-7B0F12F94E01",
            title: "Crispy Chili Oil Smash Burgers",
            creator: "@pepperandpan",
            source: .tiktok,
            slug: "smash-burgers",
            imageName: "RecipeBurger",
            minutes: 25,
            calories: 680,
            favorite: true
        ),
        makeRecipe(
            id: "B54D0E5B-8B10-410F-ADE7-7B0F12F94E02",
            title: "One-Pot Lemon Orzo with Feta",
            creator: "@miacooks",
            source: .instagram,
            slug: "lemon-orzo",
            imageName: "RecipeOrzo",
            minutes: 35,
            calories: 520
        ),
        makeRecipe(
            id: "B54D0E5B-8B10-410F-ADE7-7B0F12F94E03",
            title: "15-Minute Garlic Butter Udon",
            creator: "@noodlehouse",
            source: .tiktok,
            slug: "garlic-udon",
            imageName: "RecipeUdon",
            minutes: 15,
            calories: 610,
            favorite: true
        ),
        makeRecipe(
            id: "B54D0E5B-8B10-410F-ADE7-7B0F12F94E04",
            title: "Sheet-Pan Gochujang Chicken",
            creator: "June's Kitchen",
            source: .youtube,
            slug: "gochujang-chicken",
            imageName: "RecipeChicken",
            minutes: 45,
            calories: 560
        ),
        makeRecipe(
            id: "B54D0E5B-8B10-410F-ADE7-7B0F12F94E05",
            title: "Whipped Ricotta Toast, Hot Honey",
            creator: "@sundaytable",
            source: .instagram,
            slug: "ricotta-toast",
            imageName: "RecipeToast",
            minutes: 10,
            calories: 340
        ),
        makeRecipe(
            id: "B54D0E5B-8B10-410F-ADE7-7B0F12F94E06",
            title: "Brown Butter Miso Cookies",
            creator: "@bakeslow",
            source: .tiktok,
            slug: "miso-cookies",
            imageName: "RecipeCookies",
            minutes: 40,
            calories: 210
        ),
    ]

    static let importJobs: [ImportJob] = {
        let parsing = ImportJob.queued(
            sourceURL: URL(
                string: "https://www.tiktok.com/@cook/video/green-curry"
            )!,
            source: .tiktok,
            id: UUID(uuidString: "FD53B35A-4E30-40BE-8D90-047908528101")!,
            createdAt: baseDate.addingTimeInterval(60)
        )
        let review = transitionedJob(
            id: "FD53B35A-4E30-40BE-8D90-047908528102",
            url: "https://www.instagram.com/reel/sunday-ragu",
            source: .instagram,
            status: .needsReview
        )
        let failed = transitionedJob(
            id: "FD53B35A-4E30-40BE-8D90-047908528103",
            url: "https://www.tiktok.com/@cook/video/carbonara",
            source: .tiktok,
            status: .failed(.parserUnavailable)
        )
        return [parsing, review, failed]
    }()

    private static func makeRecipe(
        id: String,
        title: String,
        creator: String,
        source: RecipeSource,
        slug: String,
        imageName: String,
        minutes: Int,
        calories: Decimal,
        favorite: Bool = false
    ) -> Recipe {
        let recipeID = UUID(uuidString: id)!
        let ingredientID = UUID()
        return Recipe(
            id: recipeID,
            title: title,
            description: "A clean, dependable recipe rescued from the scroll.",
            creatorName: creator,
            source: source,
            originalURL: URL(string: "https://example.com/\(slug)")!,
            images: [RecipeImage(localName: imageName)],
            preparationMinutes: min(10, minutes),
            cookingMinutes: max(minutes - 10, 0),
            totalMinutes: minutes,
            servings: 4,
            ingredients: [
                Ingredient(
                    id: ingredientID,
                    quantityText: "1",
                    unit: "cup",
                    name: "featured ingredient",
                    orderIndex: 0
                ),
            ],
            steps: [
                RecipeStep(
                    orderIndex: 0,
                    instruction: "Prepare the ingredients and cook until ready.",
                    ingredientIDs: [ingredientID]
                ),
            ],
            nutrition: Nutrition(
                calories: calories,
                proteinGrams: 22,
                carbohydrateGrams: 48,
                fatGrams: 24,
                saturatedFatGrams: 8,
                fiberGrams: 4,
                sugarGrams: 6,
                sodiumMilligrams: 680,
                servingBasis: 1,
                isEstimated: true
            ),
            isFavorite: favorite,
            createdAt: baseDate.addingTimeInterval(
                TimeInterval(recipesOrderOffset(for: recipeID))
            ),
            updatedAt: baseDate
        )
    }

    private static func recipesOrderOffset(for id: UUID) -> Int {
        Int(id.uuidString.suffix(2)) ?? 0
    }

    private static func transitionedJob(
        id: String,
        url: String,
        source: RecipeSource,
        status: ImportStatus
    ) -> ImportJob {
        let queued = ImportJob.queued(
            sourceURL: URL(string: url)!,
            source: source,
            id: UUID(uuidString: id)!,
            createdAt: baseDate
        )
        do {
            return try queued.transitioning(to: status, at: baseDate)
        } catch {
            preconditionFailure("Invalid preview import transition: \(error)")
        }
    }
}
