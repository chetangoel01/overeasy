import Foundation
import LadleCore
import SwiftData

@MainActor
final class SwiftDataRecipeRepository: RecipeRepository {
    private let modelContext: ModelContext
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        modelContext: ModelContext,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.modelContext = modelContext
        self.encoder = encoder
        self.decoder = decoder
    }

    func fetchRecipes() throws -> [Recipe] {
        let descriptor = FetchDescriptor<StoredRecipe>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(decodeRecipe)
    }

    func fetchRecipe(id: UUID) throws -> Recipe? {
        var descriptor = FetchDescriptor<StoredRecipe>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(decodeRecipe)
    }

    func save(_ recipe: Recipe) throws {
        let payload = try encoder.encode(recipe)
        if let stored = try storedRecipe(id: recipe.id) {
            apply(recipe, payload: payload, to: stored)
        } else {
            modelContext.insert(makeStoredRecipe(recipe, payload: payload))
        }
        try modelContext.save()
    }

    func deleteRecipe(id: UUID) throws {
        if let stored = try storedRecipe(id: id) {
            modelContext.delete(stored)
            try modelContext.save()
        }
    }

    func fetchImportJobs() throws -> [ImportJob] {
        let descriptor = FetchDescriptor<StoredImportJob>(
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(descriptor).map(decodeImportJob)
    }

    func save(_ importJob: ImportJob) throws {
        let payload = try encoder.encode(importJob)
        if let stored = try storedImportJob(id: importJob.id) {
            apply(importJob, payload: payload, to: stored)
        } else {
            modelContext.insert(
                makeStoredImportJob(importJob, payload: payload)
            )
        }
        try modelContext.save()
    }

    func replaceRecipe(
        id: UUID,
        with recipe: Recipe,
        completing importJob: ImportJob
    ) throws {
        let recipePayload = try encoder.encode(recipe)
        let jobPayload = try encoder.encode(importJob)
        guard let current = try storedRecipe(id: id) else {
            throw CocoaError(.fileNoSuchFile)
        }

        do {
            if let stored = try storedRecipe(id: recipe.id) {
                apply(recipe, payload: recipePayload, to: stored)
            } else {
                modelContext.insert(
                    makeStoredRecipe(recipe, payload: recipePayload)
                )
            }
            if let stored = try storedImportJob(id: importJob.id) {
                apply(importJob, payload: jobPayload, to: stored)
            } else {
                modelContext.insert(
                    makeStoredImportJob(importJob, payload: jobPayload)
                )
            }
            modelContext.delete(current)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func seedIfNeeded(
        recipes: [Recipe],
        importJobs: [ImportJob]
    ) throws {
        let storedRecipeCount = try modelContext.fetchCount(
            FetchDescriptor<StoredRecipe>()
        )
        let storedJobCount = try modelContext.fetchCount(
            FetchDescriptor<StoredImportJob>()
        )
        guard storedRecipeCount == 0, storedJobCount == 0 else {
            return
        }

        let encodedRecipes = try recipes.map { recipe in
            (recipe, try encoder.encode(recipe))
        }
        let encodedJobs = try importJobs.map { job in
            (job, try encoder.encode(job))
        }

        for (recipe, payload) in encodedRecipes {
            modelContext.insert(makeStoredRecipe(recipe, payload: payload))
        }
        for (job, payload) in encodedJobs {
            modelContext.insert(makeStoredImportJob(job, payload: payload))
        }
        try modelContext.save()
    }

    private func storedRecipe(id: UUID) throws -> StoredRecipe? {
        var descriptor = FetchDescriptor<StoredRecipe>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func storedImportJob(id: UUID) throws -> StoredImportJob? {
        var descriptor = FetchDescriptor<StoredImportJob>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func makeStoredRecipe(
        _ recipe: Recipe,
        payload: Data
    ) -> StoredRecipe {
        StoredRecipe(
            id: recipe.id,
            title: recipe.title,
            creatorName: recipe.creatorName,
            totalMinutes: recipe.totalMinutes,
            calories: recipe.nutrition?.calories.map {
                NSDecimalNumber(decimal: $0).doubleValue
            },
            isFavorite: recipe.isFavorite,
            createdAt: recipe.createdAt,
            updatedAt: recipe.updatedAt,
            payload: payload
        )
    }

    private func apply(
        _ recipe: Recipe,
        payload: Data,
        to stored: StoredRecipe
    ) {
        stored.title = recipe.title
        stored.creatorName = recipe.creatorName
        stored.totalMinutes = recipe.totalMinutes
        stored.calories = recipe.nutrition?.calories.map {
            NSDecimalNumber(decimal: $0).doubleValue
        }
        stored.isFavorite = recipe.isFavorite
        stored.createdAt = recipe.createdAt
        stored.updatedAt = recipe.updatedAt
        stored.payload = payload
    }

    private func decodeRecipe(_ stored: StoredRecipe) throws -> Recipe {
        try decoder.decode(Recipe.self, from: stored.payload)
    }

    private func makeStoredImportJob(
        _ job: ImportJob,
        payload: Data
    ) -> StoredImportJob {
        StoredImportJob(
            id: job.id,
            sourceURLString: job.sourceURL.absoluteString,
            statusKey: statusKey(for: job.status),
            createdAt: job.createdAt,
            updatedAt: job.updatedAt,
            currentRecipeID: job.currentRecipeID,
            payload: payload
        )
    }

    private func apply(
        _ job: ImportJob,
        payload: Data,
        to stored: StoredImportJob
    ) {
        stored.sourceURLString = job.sourceURL.absoluteString
        stored.statusKey = statusKey(for: job.status)
        stored.createdAt = job.createdAt
        stored.updatedAt = job.updatedAt
        stored.currentRecipeID = job.currentRecipeID
        stored.payload = payload
    }

    private func decodeImportJob(_ stored: StoredImportJob) throws -> ImportJob {
        try decoder.decode(ImportJob.self, from: stored.payload)
    }

    private func statusKey(for status: ImportStatus) -> String {
        switch status {
        case .parsing:
            "parsing"
        case .ready:
            "ready"
        case .needsReview:
            "needsReview"
        case .failed:
            "failed"
        }
    }
}
