import Foundation
import LadleCore

enum PreviewFixtures {
    private static let baseDate = Date(timeIntervalSince1970: 1_784_836_000)

    /// Bundled artwork for a demo Discover row.
    ///
    /// Fixture images are asset names, not URLs, and demo builds run without
    /// a `RemoteImageCache` at all — so the only way a Discover thumbnail can
    /// render offline is the local-asset path. Discover rows carry just a URL
    /// (that is all the wire contract has), so they resolve back to the
    /// fixture by source id. Real Discover recipes always arrive with a
    /// remote URL and never reach this.
    static func discoverArtwork(sourceID: UUID) -> RecipeImage? {
        recipes.first { $0.id == sourceID }?.images.first
    }

    static let recipes: [Recipe] = [
        makeRecipe(
            id: "B54D0E5B-8B10-410F-ADE7-7B0F12F94E01",
            title: "Crispy Chili Oil Smash Burgers",
            creator: "@chebbo",
            source: .tiktok,
            slug: "smash-burgers",
            imageName: "RecipeBurger",
            minutes: 25,
            favorite: true
        ),
        makeRecipe(
            id: "B54D0E5B-8B10-410F-ADE7-7B0F12F94E02",
            title: "One-Pot Lemon Orzo with Feta",
            creator: "@miacooks",
            source: .instagram,
            slug: "lemon-orzo",
            imageName: "RecipeOrzo",
            minutes: 35
        ),
        makeRecipe(
            id: "B54D0E5B-8B10-410F-ADE7-7B0F12F94E03",
            title: "15-Minute Garlic Butter Udon",
            creator: "@iankyo",
            source: .tiktok,
            slug: "garlic-udon",
            imageName: "RecipeUdon",
            minutes: 15,
            favorite: true
        ),
        makeRecipe(
            id: "B54D0E5B-8B10-410F-ADE7-7B0F12F94E04",
            title: "Sheet-Pan Gochujang Chicken",
            creator: "JZ Eats",
            source: .youtube,
            slug: "gochujang-chicken",
            imageName: "RecipeChicken",
            minutes: 45
        ),
        makeRecipe(
            id: "B54D0E5B-8B10-410F-ADE7-7B0F12F94E05",
            title: "Whipped Ricotta Toast, Hot Honey",
            creator: "@sundaytable",
            source: .instagram,
            slug: "ricotta-toast",
            imageName: "RecipeToast",
            minutes: 10
        ),
        makeRecipe(
            id: "B54D0E5B-8B10-410F-ADE7-7B0F12F94E06",
            title: "Brown Butter Miso Cookies",
            creator: "@iramsfoodstory",
            source: .tiktok,
            slug: "miso-cookies",
            imageName: "RecipeCookies",
            minutes: 40
        ),
    ]

    static let largeLibraryRecipes: [Recipe] = {
        let slugs = [
            "smash-burgers",
            "lemon-orzo",
            "garlic-udon",
            "gochujang-chicken",
            "ricotta-toast",
            "miso-cookies",
        ]
        return (1...80).map { index in
            let template = recipes[(index - 1) % recipes.count]
            return makeRecipe(
                id: String(
                    format: "C54D0E5B-8B10-410F-ADE7-%012X",
                    index
                ),
                title: String(format: "Weeknight Recipe %02d", index),
                creator: template.creatorName ?? "Overeasy Kitchen",
                source: template.source,
                slug: slugs[(index - 1) % slugs.count],
                imageName: template.images.first?.localName ?? "RecipeBurger",
                minutes: template.totalMinutes ?? 30,
                favorite: index.isMultiple(of: 7)
            )
        }
    }()

    static let importJobs: [ImportJob] = {
        let parsing = ImportJob.queued(
            sourceURL: URL(
                string: "https://www.tiktok.com/@cook/video/green-curry"
            )!,
            source: .tiktok,
            id: UUID(uuidString: "FD53B35A-4E30-40BE-8D90-047908528101")!,
            createdAt: baseDate.addingTimeInterval(60)
        )
        let review = reviewJob(
            id: "FD53B35A-4E30-40BE-8D90-047908528102",
            recipe: recipes[1]
        )
        let failed = transitionedJob(
            id: "FD53B35A-4E30-40BE-8D90-047908528103",
            url: "https://www.tiktok.com/@cook/video/carbonara",
            source: .tiktok,
            status: .failed(.parserUnavailable)
        )
        return [parsing, review, failed]
    }()

    private struct RecipeContent {
        let description: String
        let ingredients: [Ingredient]
        let steps: [RecipeStep]
        let nutrition: Nutrition
    }

    private static func makeRecipe(
        id: String,
        title: String,
        creator: String,
        source: RecipeSource,
        slug: String,
        imageName: String,
        minutes: Int,
        favorite: Bool = false
    ) -> Recipe {
        let recipeID = UUID(uuidString: id)!
        let content = recipeContent(for: slug)
        return Recipe(
            id: recipeID,
            title: title,
            description: content.description,
            creatorName: creator,
            source: source,
            originalURL: previewVideoURL(for: slug),
            images: [RecipeImage(localName: imageName)],
            preparationMinutes: min(10, minutes),
            cookingMinutes: max(minutes - 10, 0),
            totalMinutes: minutes,
            servings: 4,
            ingredients: content.ingredients,
            steps: content.steps,
            nutrition: content.nutrition,
            isFavorite: favorite,
            createdAt: baseDate.addingTimeInterval(
                TimeInterval(recipesOrderOffset(for: recipeID))
            ),
            updatedAt: baseDate
        )
    }

    private static func previewVideoURL(for slug: String) -> URL {
        let value = switch slug {
        case "smash-burgers":
            "https://www.tiktok.com/@chebbo/video/7364345055881989392"
        case "garlic-udon":
            "https://www.tiktok.com/@iankyo/video/7436430114910506271"
        case "miso-cookies":
            "https://www.tiktok.com/@iramsfoodstory/video/7445012169432763690"
        case "lemon-orzo", "ricotta-toast":
            "https://www.instagram.com/reel/DbbHIKHM3xr/"
        case "gochujang-chicken":
            "https://www.youtube.com/shorts/Cb0wIOhTQsE"
        default:
            "https://example.com/\(slug)"
        }
        return URL(string: value)!
    }

    private static func nutrition(
        calories: Decimal,
        protein: Decimal,
        carbs: Decimal,
        fat: Decimal,
        saturatedFat: Decimal,
        fiber: Decimal,
        sugar: Decimal,
        sodium: Decimal
    ) -> Nutrition {
        Nutrition(
            calories: calories,
            proteinGrams: protein,
            carbohydrateGrams: carbs,
            fatGrams: fat,
            saturatedFatGrams: saturatedFat,
            fiberGrams: fiber,
            sugarGrams: sugar,
            sodiumMilligrams: sodium,
            servingBasis: 1,
            isEstimated: true
        )
    }

    // swiftlint:disable:next function_body_length
    private static func recipeContent(for slug: String) -> RecipeContent {
        switch slug {
        case "smash-burgers":
            let ingredients = orderedIngredients([
                ("1", "lb", "ground beef", "80/20, in four loose balls"),
                ("4", nil, "potato rolls", "split"),
                ("4", "slices", "American cheese", nil),
                ("3", "tbsp", "chili crisp", nil),
                ("2", "tbsp", "mayonnaise", nil),
                ("½", nil, "small white onion", "shaved thin"),
                ("1", "tsp", "kosher salt", nil),
                ("1", "tbsp", "neutral oil", "for the griddle"),
            ])
            return RecipeContent(
                description:
                    "Lacy-edged smash patties glazed with crunchy chili crisp.",
                ingredients: ingredients,
                steps: orderedSteps([
                    (
                        "Divide the beef into four loose balls without packing them tight.",
                        [ingredients[0].id],
                        []
                    ),
                    (
                        "Heat a lightly oiled griddle until smoking, smash the balls flat, season with salt, and cook until deeply crusted.",
                        [ingredients[0].id, ingredients[6].id, ingredients[7].id],
                        [("Crust the patties", 120)]
                    ),
                    (
                        "Flip, top each patty with cheese and a spoonful of chili crisp, and cook one minute more.",
                        [ingredients[2].id, ingredients[3].id],
                        []
                    ),
                    (
                        "Stack on mayo-spread rolls with the shaved onion and serve hot.",
                        [ingredients[1].id, ingredients[4].id, ingredients[5].id],
                        []
                    ),
                ]),
                nutrition: nutrition(
                    calories: 680, protein: 38, carbs: 35, fat: 42,
                    saturatedFat: 16, fiber: 2, sugar: 6, sodium: 1150
                )
            )

        case "lemon-orzo":
            let ingredients = orderedIngredients([
                ("1", "cup", "orzo", nil),
                ("2", "cloves", "garlic", "finely chopped"),
                ("2", "cups", "vegetable stock", nil),
                ("1", nil, "lemon", "zested and juiced"),
                ("½", "cup", "crumbled feta", nil),
                ("2", "tbsp", "extra-virgin olive oil", nil),
            ])
            return RecipeContent(
                description:
                    "Creamy lemon orzo with salty feta and a bright, silky finish.",
                ingredients: ingredients,
                steps: orderedSteps([
                    (
                        "Toast the orzo with garlic until the edges turn golden.",
                        [ingredients[0].id, ingredients[1].id],
                        []
                    ),
                    (
                        "Pour in the stock and simmer, stirring often, until creamy.",
                        [ingredients[2].id],
                        [("Simmer orzo", 720)]
                    ),
                    (
                        "Fold in the lemon zest, juice, and half of the feta.",
                        [ingredients[3].id, ingredients[4].id],
                        []
                    ),
                    (
                        "Finish with olive oil and the remaining feta, then serve.",
                        [ingredients[4].id, ingredients[5].id],
                        []
                    ),
                ]),
                nutrition: nutrition(
                    calories: 520, protein: 16, carbs: 62, fat: 22,
                    saturatedFat: 8, fiber: 4, sugar: 5, sodium: 890
                )
            )

        case "garlic-udon":
            let ingredients = orderedIngredients([
                ("14", "oz", "frozen udon", "two blocks"),
                ("3", "tbsp", "unsalted butter", nil),
                ("4", "cloves", "garlic", "minced"),
                ("1", "tbsp", "soy sauce", nil),
                ("2", "tsp", "oyster sauce", nil),
                ("2", nil, "scallions", "sliced thin"),
                ("1", "pinch", "chili flakes", nil),
                ("1", nil, "soft-boiled egg", "optional"),
            ])
            return RecipeContent(
                description:
                    "Chewy frozen udon tossed in a garlicky soy butter glaze.",
                ingredients: ingredients,
                steps: orderedSteps([
                    (
                        "Drop the udon into boiling water just until the noodles loosen, then drain.",
                        [ingredients[0].id],
                        [("Loosen udon", 90)]
                    ),
                    (
                        "Melt the butter over low heat and cook the garlic until fragrant but not browned.",
                        [ingredients[1].id, ingredients[2].id],
                        []
                    ),
                    (
                        "Add the soy and oyster sauces, then toss in the noodles with a splash of their cooking water until glossy.",
                        [ingredients[3].id, ingredients[4].id],
                        []
                    ),
                    (
                        "Top with scallions, chili flakes, and the egg if using.",
                        [ingredients[5].id, ingredients[6].id, ingredients[7].id],
                        []
                    ),
                ]),
                nutrition: nutrition(
                    calories: 610, protein: 14, carbs: 78, fat: 26,
                    saturatedFat: 12, fiber: 4, sugar: 6, sodium: 1240
                )
            )

        case "gochujang-chicken":
            let ingredients = orderedIngredients([
                ("2", "lb", "boneless skin-on chicken thighs", nil),
                ("3", "tbsp", "gochujang", nil),
                ("2", "tbsp", "honey", nil),
                ("1", "tbsp", "soy sauce", nil),
                ("1", "tbsp", "rice vinegar", nil),
                ("2", "tsp", "toasted sesame oil", nil),
                ("3", "cloves", "garlic", "grated"),
                ("1", "bunch", "scallions", "cut into two-inch pieces"),
                ("4", "cups", "steamed rice", "to serve"),
            ])
            return RecipeContent(
                description:
                    "Sticky-glazed chicken thighs roasted over charred scallions.",
                ingredients: ingredients,
                steps: orderedSteps([
                    (
                        "Whisk the gochujang, honey, soy, vinegar, sesame oil, and garlic, then coat the chicken.",
                        ingredients[1...6].map(\.id) + [ingredients[0].id],
                        []
                    ),
                    (
                        "Scatter the scallions on a sheet pan, set the thighs on top, and roast at 425°F.",
                        [ingredients[0].id, ingredients[7].id],
                        [("First roast", 1200)]
                    ),
                    (
                        "Baste with the pan glaze and roast until the edges char.",
                        [ingredients[0].id],
                        [("Finish roast", 540)]
                    ),
                    (
                        "Rest five minutes, then serve over rice with the pan juices spooned on top.",
                        [ingredients[8].id],
                        []
                    ),
                ]),
                nutrition: nutrition(
                    calories: 560, protein: 42, carbs: 46, fat: 22,
                    saturatedFat: 5, fiber: 2, sugar: 14, sodium: 980
                )
            )

        case "ricotta-toast":
            let ingredients = orderedIngredients([
                ("4", "slices", "sourdough", "cut thick"),
                ("1", "cup", "whole-milk ricotta", nil),
                ("2", "tbsp", "olive oil", "plus more for the pan"),
                ("1½", "tbsp", "hot honey", nil),
                ("1", "pinch", "flaky salt", nil),
                ("1", "tsp", "fresh thyme leaves", nil),
                ("1", "pinch", "black pepper", nil),
            ])
            return RecipeContent(
                description:
                    "Blistered sourdough under clouds of whipped ricotta and hot honey.",
                ingredients: ingredients,
                steps: orderedSteps([
                    (
                        "Whip the ricotta with the olive oil and a pinch of salt until smooth and airy.",
                        [ingredients[1].id, ingredients[2].id, ingredients[4].id],
                        []
                    ),
                    (
                        "Griddle the bread in olive oil until deeply golden on both sides.",
                        [ingredients[0].id, ingredients[2].id],
                        []
                    ),
                    (
                        "Swoosh the ricotta over each slice and drizzle with hot honey.",
                        [ingredients[1].id, ingredients[3].id],
                        []
                    ),
                    (
                        "Finish with thyme, flaky salt, and black pepper.",
                        [ingredients[4].id, ingredients[5].id, ingredients[6].id],
                        []
                    ),
                ]),
                nutrition: nutrition(
                    calories: 340, protein: 14, carbs: 34, fat: 16,
                    saturatedFat: 7, fiber: 2, sugar: 9, sodium: 520
                )
            )

        case "miso-cookies":
            let ingredients = orderedIngredients([
                ("1", "cup", "unsalted butter", nil),
                ("2", "tbsp", "white miso", nil),
                ("1¼", "cups", "brown sugar", "packed"),
                ("1", nil, "egg", "plus one yolk"),
                ("2", "cups", "all-purpose flour", nil),
                ("1", "tsp", "baking soda", nil),
                ("½", "tsp", "fine salt", nil),
                ("¼", "cup", "granulated sugar", "for rolling"),
            ])
            return RecipeContent(
                description:
                    "Chewy cookies with brown-butter depth and a savory miso edge.",
                ingredients: ingredients,
                steps: orderedSteps([
                    (
                        "Brown the butter until nutty and let it cool until just warm.",
                        [ingredients[0].id],
                        [("Cool brown butter", 900)]
                    ),
                    (
                        "Whisk the brown butter with the miso and brown sugar, then beat in the egg and yolk.",
                        ingredients[1...3].map(\.id),
                        []
                    ),
                    (
                        "Fold in the flour, baking soda, and salt, then chill the dough briefly.",
                        ingredients[4...6].map(\.id),
                        [("Chill dough", 600)]
                    ),
                    (
                        "Roll balls in granulated sugar and bake at 350°F until the edges set and the centers stay soft.",
                        [ingredients[7].id],
                        [("Bake cookies", 660)]
                    ),
                ]),
                nutrition: nutrition(
                    calories: 210, protein: 3, carbs: 28, fat: 10,
                    saturatedFat: 6, fiber: 1, sugar: 18, sodium: 220
                )
            )

        default:
            preconditionFailure("Unknown preview recipe slug: \(slug)")
        }
    }

    private static func orderedIngredients(
        _ rows: [(String?, String?, String, String?)]
    ) -> [Ingredient] {
        rows.enumerated().map { index, row in
            Ingredient(
                quantityText: row.0,
                unit: row.1,
                name: row.2,
                preparation: row.3,
                orderIndex: index
            )
        }
    }

    private static func orderedSteps(
        _ rows: [(String, [UUID], [(String, Int)])]
    ) -> [RecipeStep] {
        rows.enumerated().map { index, row in
            RecipeStep(
                orderIndex: index,
                instruction: row.0,
                ingredientIDs: row.1,
                timers: row.2.map {
                    DetectedTimer(label: $0.0, durationSeconds: $0.1)
                }
            )
        }
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

    private static func reviewJob(
        id: String,
        recipe: Recipe
    ) -> ImportJob {
        let queued = ImportJob.queued(
            sourceURL: recipe.originalURL,
            source: recipe.source,
            id: UUID(uuidString: id)!,
            createdAt: baseDate
        )
        do {
            return try queued.awaitingReview(
                recipeID: recipe.id,
                at: baseDate
            )
        } catch {
            preconditionFailure("Invalid preview review job: \(error)")
        }
    }
}
