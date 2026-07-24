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
    private var jobs: [String: ImportJob] = [:]
    private var updates: [String: ImportServiceUpdate] = [:]

    init(slowDelay: Duration = .seconds(3)) {
        self.slowDelay = slowDelay
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
        let ingredientID = uuid(details.identifierPrefix, suffix: "02")
        let uncertainty = kind == .ragu
            ? FieldUncertainty(
                field: "ingredients[0].quantityText",
                reason: "The quantity was not spoken clearly.",
                confidence: 0.58
            )
            : nil

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
            ingredients: [
                Ingredient(
                    id: ingredientID,
                    quantityText: kind == .ragu ? nil : "1",
                    unit: kind == .ragu ? nil : "batch",
                    name: details.featuredIngredient,
                    orderIndex: 0,
                    uncertainty: uncertainty
                ),
            ],
            steps: [
                RecipeStep(
                    id: uuid(details.identifierPrefix, suffix: "04"),
                    orderIndex: 0,
                    instruction: details.instruction,
                    ingredientIDs: [ingredientID],
                    uncertainty: uncertainty
                ),
            ],
            nutrition: Nutrition(
                calories: details.calories,
                proteinGrams: 18,
                carbohydrateGrams: 42,
                fatGrams: 21,
                saturatedFatGrams: 7,
                fiberGrams: 5,
                sugarGrams: 6,
                sodiumMilligrams: 640,
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
                description: "A bright coconut curry rescued from the scroll.",
                creator: "@ladlekitchen",
                imageName: "RecipeChicken",
                preparationMinutes: 12,
                cookingMinutes: 23,
                calories: 480,
                featuredIngredient: "green curry paste",
                instruction: "Simmer the curry until fragrant and glossy."
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
                featuredIngredient: "crushed tomatoes",
                instruction: "Simmer gently, then check the seasoning."
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
                featuredIngredient: "orzo",
                instruction: "Cook the orzo until creamy, then fold in feta."
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
                featuredIngredient: "pasted ingredients",
                instruction: "Follow the pasted recipe details."
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
    let identifierPrefix: String
    let title: String
    let description: String
    let creator: String?
    let imageName: String?
    let preparationMinutes: Int
    let cookingMinutes: Int
    let calories: Decimal
    let featuredIngredient: String
    let instruction: String
}
