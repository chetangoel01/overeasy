import Foundation
import LadleCore

actor DemoImportService: ImportService {
    private enum DemoError: Error {
        case unknownJob
    }

    private enum DemoRecipeKind {
        case greenCurry
        case ragu
        case orzo
        case pasted
    }

    let slowDelay: Duration
    private let forcedFailure: APIError?
    private var jobs: [String: ImportJob] = [:]
    private var updates: [String: ImportServiceUpdate] = [:]

    init(
        slowDelay: Duration = .seconds(3),
        forcedFailure: APIError? = nil
    ) {
        self.slowDelay = slowDelay
        self.forcedFailure = forcedFailure
    }

    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        let remoteJobID = job.id.uuidString.lowercased()
        jobs[remoteJobID] = job
        let update = ImportServiceUpdate(
            remoteJobID: remoteJobID,
            progress: try await progress(for: job)
        )
        updates[remoteJobID] = update
        return update
    }

    func status(
        remoteJobID: String
    ) async throws -> ImportServiceUpdate {
        guard let update = updates[remoteJobID.lowercased()] else {
            throw DemoError.unknownJob
        }
        return update
    }

    func retry(
        remoteJobID: String,
        correctionNotes: String?,
        pastedRecipeText: String?
    ) async throws -> ImportServiceUpdate {
        let key = remoteJobID.lowercased()
        guard var job = jobs[key] else {
            throw DemoError.unknownJob
        }
        job.correctionNotes = correctionNotes
        job.pastedRecipeText = pastedRecipeText
        jobs[key] = job
        let update = ImportServiceUpdate(
            remoteJobID: key,
            progress: try await progress(for: job)
        )
        updates[key] = update
        return update
    }

    private func progress(
        for job: ImportJob
    ) async throws -> ImportServiceProgress {
        if let forcedFailure {
            throw forcedFailure
        }
        let slug = job.sourceURL.absoluteString.lowercased()

        if slug.contains("slow") {
            try await Task.sleep(for: slowDelay)
        }
        try Task.checkCancellation()

        if let pastedRecipeText = job.pastedRecipeText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !pastedRecipeText.isEmpty {
            return .ready(
                makeRecipe(
                    kind: .pasted,
                    job: job,
                    pastedRecipeText: pastedRecipeText
                )
            )
        }

        if let correctionNotes = job.correctionNotes?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !correctionNotes.isEmpty {
            if correctionNotes.localizedCaseInsensitiveContains(
                "simulate failure"
            ) {
                return .failed(.parserUnavailable)
            }
            let kind: DemoRecipeKind = slug.contains("orzo")
                ? .orzo
                : .greenCurry
            return .ready(makeRecipe(kind: kind, job: job))
        }

        if slug.contains("cancelled") {
            // The server reports a job the user had already cancelled,
            // e.g. from another session.
            throw RemoteContractError.importCancelled
        }
        if slug.contains("private") || slug.contains("deleted") {
            return .failed(.privateOrDeleted)
        }
        if slug.contains("network") || slug.contains("offline") {
            return .failed(.networkUnavailable)
        }
        if slug.contains("parser") || slug.contains("failed") {
            return .failed(.parserUnavailable)
        }
        if slug.contains("needs-review") || slug.contains("review") {
            return .needsReview(
                makeRecipe(
                    kind: .ragu,
                    job: job
                )
            )
        }

        let kind: DemoRecipeKind = slug.contains("orzo")
            ? .orzo
            : .greenCurry
        return .ready(
            makeRecipe(
                kind: kind,
                job: job
            )
        )
    }

    private func makeRecipe(
        kind: DemoRecipeKind,
        job: ImportJob,
        pastedRecipeText: String? = nil
    ) -> Recipe {
        let details = details(for: kind, pastedRecipeText: pastedRecipeText)
        let uncertainty = kind == .ragu
            ? FieldUncertainty(
                field: "ingredients[0].quantityText",
                reason: "The quantity was not spoken clearly.",
                confidence: 0.58
            )
            : nil

        let ingredients = details.ingredients.enumerated().map {
            index, row in
            Ingredient(
                id: uuid(
                    details.identifierPrefix,
                    suffix: String(format: "%02d", 10 + index)
                ),
                quantityText: row.quantity,
                unit: row.unit,
                name: row.name,
                preparation: row.preparation,
                orderIndex: index,
                uncertainty: index == 0 ? uncertainty : nil
            )
        }

        let steps = details.steps.enumerated().map { index, row in
            RecipeStep(
                id: uuid(
                    details.identifierPrefix,
                    suffix: String(format: "%02d", 40 + index)
                ),
                orderIndex: index,
                instruction: row.instruction,
                ingredientIDs: row.ingredientIndexes.map { ingredients[$0].id },
                timers: row.timer.map {
                    [
                        DetectedTimer(
                            id: uuid(
                                details.identifierPrefix,
                                suffix: String(format: "%02d", 70 + index)
                            ),
                            label: $0.label,
                            durationSeconds: $0.seconds
                        ),
                    ]
                } ?? [],
                uncertainty: index == 0 ? uncertainty : nil
            )
        }

        return Recipe(
            id: job.candidateRecipeID ?? job.id,
            title: details.title,
            description: details.description,
            creatorName: details.creator,
            source: job.source,
            originalURL: job.sourceURL,
            images: [
                RecipeImage(
                    id: uuid(details.identifierPrefix, suffix: "03"),
                    localName: details.imageName
                ),
            ],
            preparationMinutes: details.preparationMinutes,
            cookingMinutes: details.cookingMinutes,
            totalMinutes: (
                details.preparationMinutes + details.cookingMinutes
            ),
            servings: 4,
            ingredients: ingredients,
            steps: steps,
            nutrition: Nutrition(
                calories: details.calories,
                proteinGrams: details.proteinGrams,
                carbohydrateGrams: details.carbohydrateGrams,
                fatGrams: details.fatGrams,
                saturatedFatGrams: 7,
                fiberGrams: 5,
                sugarGrams: 6,
                sodiumMilligrams: details.sodiumMilligrams,
                servingBasis: 1,
                isEstimated: true
            ),
            reviewStatus: kind == .ragu ? .needsReview : .ready,
            uncertainties: uncertainty.map { [$0] } ?? [],
            createdAt: Date(timeIntervalSince1970: 1_784_836_500),
            updatedAt: Date(timeIntervalSince1970: 1_784_836_500)
        )
    }

    private func details(
        for kind: DemoRecipeKind,
        pastedRecipeText: String?
    ) -> DemoRecipeDetails {
        switch kind {
        case .greenCurry:
            DemoRecipeDetails(
                identifierPrefix: "A1010101",
                title: "Weeknight Green Curry",
                description: "A bright coconut curry that comes together on one burner.",
                creator: "@ladlekitchen",
                imageName: "RecipeChicken",
                preparationMinutes: 12,
                cookingMinutes: 23,
                calories: 480,
                proteinGrams: 28,
                carbohydrateGrams: 38,
                fatGrams: 24,
                sodiumMilligrams: 940,
                ingredients: [
                    .init("3", "tbsp", "green curry paste", nil),
                    .init("1", "can", "coconut milk", "14 oz, unshaken"),
                    .init("1", "lb", "chicken thighs", "sliced thin"),
                    .init("1", "cup", "green beans", "trimmed"),
                    .init("1", nil, "red bell pepper", "sliced"),
                    .init("1", "tbsp", "fish sauce", nil),
                    .init("1", "tsp", "brown sugar", nil),
                    .init("1", "handful", "Thai basil", nil),
                    .init("4", "cups", "jasmine rice", "steamed, to serve"),
                ],
                steps: [
                    .init(
                        "Fry the curry paste in the thick coconut cream from the top of the can until fragrant.",
                        [0, 1],
                        nil
                    ),
                    .init(
                        "Add the chicken and stir until coated and just opaque.",
                        [2],
                        nil
                    ),
                    .init(
                        "Pour in the rest of the coconut milk with the beans and pepper, then simmer until tender.",
                        [1, 3, 4],
                        ("Simmer curry", 600)
                    ),
                    .init(
                        "Season with fish sauce and sugar, tear in the basil, and serve over rice.",
                        [5, 6, 7, 8],
                        nil
                    ),
                ]
            )
        case .ragu:
            DemoRecipeDetails(
                identifierPrefix: "A2020202",
                title: "Sunday Tomato Ragu",
                description: "A slow tomato sauce that needs one quick check.",
                creator: "@sundaytable",
                imageName: "RecipeOrzo",
                preparationMinutes: 15,
                cookingMinutes: 45,
                calories: 530,
                proteinGrams: 30,
                carbohydrateGrams: 40,
                fatGrams: 26,
                sodiumMilligrams: 1040,
                ingredients: [
                    .init(nil, nil, "crushed tomatoes", nil),
                    .init("1", "lb", "ground pork and beef", "mixed"),
                    .init("1", nil, "yellow onion", "diced"),
                    .init("3", "cloves", "garlic", "minced"),
                    .init("2", "tbsp", "tomato paste", nil),
                    .init("½", "cup", "red wine", nil),
                    .init("1", nil, "parmesan rind", "optional"),
                    .init("1", "tsp", "kosher salt", "plus more to taste"),
                ],
                steps: [
                    .init(
                        "Brown the meat hard in a wide pot, then push it to the side.",
                        [1],
                        nil
                    ),
                    .init(
                        "Soften the onion and garlic, then fry the tomato paste until brick red.",
                        [2, 3, 4],
                        nil
                    ),
                    .init(
                        "Deglaze with the wine and let it reduce by half.",
                        [5],
                        nil
                    ),
                    .init(
                        "Add the tomatoes and parmesan rind and simmer low and slow.",
                        [0, 6],
                        ("Simmer ragu", 2700)
                    ),
                    .init(
                        "Season with salt, then check the seasoning before serving.",
                        [7],
                        nil
                    ),
                ]
            )
        case .orzo:
            DemoRecipeDetails(
                identifierPrefix: "A3030303",
                title: "One-Pot Lemon Orzo with Feta",
                description: "A creamy one-pot dinner with plenty of lemon.",
                creator: "@miacooks",
                imageName: "RecipeOrzo",
                preparationMinutes: 10,
                cookingMinutes: 25,
                calories: 520,
                proteinGrams: 16,
                carbohydrateGrams: 62,
                fatGrams: 22,
                sodiumMilligrams: 890,
                ingredients: [
                    .init("1", "cup", "orzo", nil),
                    .init("2", "cloves", "garlic", "finely chopped"),
                    .init("2", "cups", "vegetable stock", nil),
                    .init("1", nil, "lemon", "zested and juiced"),
                    .init("½", "cup", "crumbled feta", nil),
                    .init("2", "tbsp", "extra-virgin olive oil", nil),
                ],
                steps: [
                    .init(
                        "Toast the orzo with garlic until the edges turn golden.",
                        [0, 1],
                        nil
                    ),
                    .init(
                        "Pour in the stock and simmer, stirring often, until creamy.",
                        [2],
                        ("Simmer orzo", 720)
                    ),
                    .init(
                        "Fold in the lemon zest, juice, and half of the feta.",
                        [3, 4],
                        nil
                    ),
                    .init(
                        "Finish with olive oil and the remaining feta, then serve.",
                        [4, 5],
                        nil
                    ),
                ]
            )
        case .pasted:
            DemoRecipeDetails(
                identifierPrefix: "A4040404",
                title: pastedTitle(from: pastedRecipeText),
                description: pastedRecipeText ?? "Recipe details added by hand.",
                creator: nil,
                imageName: nil,
                preparationMinutes: 10,
                cookingMinutes: 20,
                calories: 450,
                proteinGrams: 18,
                carbohydrateGrams: 42,
                fatGrams: 21,
                sodiumMilligrams: 640,
                ingredients: [
                    .init("1", "batch", "ingredients from your pasted text", nil),
                ],
                steps: [
                    .init(
                        "Follow the method from your pasted recipe text.",
                        [0],
                        nil
                    ),
                ]
            )
        }
    }

    private func pastedTitle(from text: String?) -> String {
        let firstLine = text?
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine, !firstLine.isEmpty else {
            return "Manual Recipe"
        }
        return firstLine
    }

    private func uuid(_ prefix: String, suffix: String) -> UUID {
        UUID(
            uuidString: "\(prefix)-0000-4000-8000-0000000000\(suffix)"
        )!
    }
}

private struct DemoRecipeDetails {
    struct IngredientRow {
        let quantity: String?
        let unit: String?
        let name: String
        let preparation: String?

        init(
            _ quantity: String?,
            _ unit: String?,
            _ name: String,
            _ preparation: String?
        ) {
            self.quantity = quantity
            self.unit = unit
            self.name = name
            self.preparation = preparation
        }
    }

    struct StepRow {
        let instruction: String
        let ingredientIndexes: [Int]
        let timer: (label: String, seconds: Int)?

        init(
            _ instruction: String,
            _ ingredientIndexes: [Int],
            _ timer: (label: String, seconds: Int)?
        ) {
            self.instruction = instruction
            self.ingredientIndexes = ingredientIndexes
            self.timer = timer
        }
    }

    let identifierPrefix: String
    let title: String
    let description: String
    let creator: String?
    let imageName: String?
    let preparationMinutes: Int
    let cookingMinutes: Int
    let calories: Decimal
    let proteinGrams: Decimal
    let carbohydrateGrams: Decimal
    let fatGrams: Decimal
    let sodiumMilligrams: Decimal
    let ingredients: [IngredientRow]
    let steps: [StepRow]
}
