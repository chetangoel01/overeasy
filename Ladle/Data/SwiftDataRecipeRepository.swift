import Foundation
import LadleCore
import SwiftData

@MainActor
final class SwiftDataRecipeRepository:
    RecipeRepository,
    RecipeSyncRepository,
    RecipeSyncConflictRepository
{
    private enum PendingMutation: String {
        case upsert
        case delete
    }

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
            predicate: #Predicate { !$0.isTombstoned },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(decodeRecipe)
    }

    func fetchRecipe(id: UUID) throws -> Recipe? {
        var descriptor = FetchDescriptor<StoredRecipe>(
            predicate: #Predicate { $0.id == id && !$0.isTombstoned }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(decodeRecipe)
    }

    func save(_ recipe: Recipe) throws {
        let payload = try encoder.encode(recipe)
        if let stored = try storedRecipe(id: recipe.id) {
            apply(recipe, payload: payload, to: stored)
            stored.isTombstoned = false
            stored.pendingMutationKey = PendingMutation.upsert.rawValue
        } else {
            modelContext.insert(
                makeStoredRecipe(
                    recipe,
                    payload: payload,
                    pendingMutation: .upsert
                )
            )
        }
        try modelContext.save()
    }

    func saveRemote(_ recipe: Recipe, revision: Int) throws {
        let payload = try encoder.encode(recipe)
        if let stored = try storedRecipe(id: recipe.id) {
            apply(recipe, payload: payload, to: stored)
            stored.serverRevision = revision
            stored.pendingMutationKey = nil
            stored.isTombstoned = false
            stored.conflictRemotePayload = nil
            stored.conflictRemoteRevision = nil
        } else {
            modelContext.insert(
                makeStoredRecipe(
                    recipe,
                    payload: payload,
                    serverRevision: revision
                )
            )
        }
        try modelContext.save()
    }

    func deleteRecipe(id: UUID) throws {
        if let stored = try storedRecipe(id: id) {
            if stored.serverRevision == 0 {
                modelContext.delete(stored)
            } else {
                stored.isTombstoned = true
                stored.pendingMutationKey = PendingMutation.delete.rawValue
                stored.updatedAt = .now
            }
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

    func deleteImportJob(id: UUID) throws {
        if let stored = try storedImportJob(id: id) {
            modelContext.delete(stored)
            try modelContext.save()
        }
    }

    /// Drops every local row without queueing remote deletions — used on
    /// sign-out, where the server copy must stay untouched.
    func wipeAllData() throws {
        try modelContext.delete(model: StoredRecipe.self)
        try modelContext.delete(model: StoredImportJob.self)
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

    func completeReview(
        recipe: Recipe,
        importJobs: [ImportJob]
    ) throws {
        do {
            let recipePayload = try encoder.encode(recipe)
            if let stored = try storedRecipe(id: recipe.id) {
                apply(recipe, payload: recipePayload, to: stored)
                stored.isTombstoned = false
                stored.pendingMutationKey = PendingMutation.upsert.rawValue
            } else {
                modelContext.insert(
                    makeStoredRecipe(
                        recipe,
                        payload: recipePayload,
                        pendingMutation: .upsert
                    )
                )
            }
            for job in importJobs {
                let payload = try encoder.encode(job)
                if let stored = try storedImportJob(id: job.id) {
                    apply(job, payload: payload, to: stored)
                } else {
                    modelContext.insert(
                        makeStoredImportJob(job, payload: payload)
                    )
                }
            }
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
            modelContext.insert(
                makeStoredRecipe(recipe, payload: payload)
            )
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
        payload: Data,
        serverRevision: Int = 0,
        pendingMutation: PendingMutation? = nil
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
            payload: payload,
            serverRevision: serverRevision,
            pendingMutationKey: pendingMutation?.rawValue
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

    func pendingRecipeMutations() throws -> [PendingRecipeMutation] {
        let descriptor = FetchDescriptor<StoredRecipe>(
            sortBy: [SortDescriptor(\.updatedAt)]
        )
        return try modelContext.fetch(descriptor).compactMap { stored in
            switch stored.pendingMutationKey.flatMap(
                PendingMutation.init(rawValue:)
            ) {
            case .upsert:
                return .upsert(
                    recipe: try decodeRecipe(stored),
                    baseRevision: stored.serverRevision
                )
            case .delete:
                return .delete(
                    recipeID: stored.id,
                    baseRevision: stored.serverRevision
                )
            case nil:
                return nil
            }
        }
    }

    func markUpsertSynced(
        _ remoteRecipe: RemoteRecipeDTO,
        pushed: Recipe
    ) throws {
        guard let stored = try storedRecipe(id: remoteRecipe.id) else {
            // The row is gone, so the user hard-deleted it while the PUT was
            // in flight (finding #28: a never-synced recipe is dropped
            // without a tombstone). Re-inserting the server's copy here would
            // resurrect it; the server-side delete is #28's to fix.
            return
        }
        let stillPendingTheSameUpsert =
            stored.isTombstoned == false
            && stored.pendingMutationKey == PendingMutation.upsert.rawValue
        let matchesPush = try stillPendingTheSameUpsert
            && decodeRecipe(stored) == pushed
        guard matchesPush else {
            // The user changed the recipe while the PUT was in flight.
            // Adopting the server's copy here would erase that change and
            // clear the pending mutation, so it would never be pushed either.
            // Keep it and rebase it on the revision the server just assigned.
            stored.serverRevision = remoteRecipe.revision
            try modelContext.save()
            return
        }
        try saveRemote(
            remoteRecipe.recipe(),
            revision: remoteRecipe.revision
        )
    }

    func markDeleteSynced(recipeID: UUID) throws {
        if let stored = try storedRecipe(id: recipeID) {
            modelContext.delete(stored)
            try modelContext.save()
        }
    }

    func preserveConflict(
        localRecipeID: UUID,
        remoteRecipe: RemoteRecipeDTO,
        remoteRevision: Int
    ) throws {
        guard let stored = try storedRecipe(id: localRecipeID) else {
            return
        }
        stored.conflictRemotePayload = try encoder.encode(
            remoteRecipe.recipe()
        )
        stored.conflictRemoteRevision = remoteRevision
        try modelContext.save()
    }

    func syncConflict(
        recipeID: UUID
    ) throws -> (recipe: Recipe, revision: Int)? {
        guard
            let stored = try storedRecipe(id: recipeID),
            let payload = stored.conflictRemotePayload,
            let revision = stored.conflictRemoteRevision
        else {
            return nil
        }
        return (
            recipe: try decoder.decode(Recipe.self, from: payload),
            revision: revision
        )
    }

    func fetchSyncConflicts() throws -> [RecipeSyncConflict] {
        let descriptor = FetchDescriptor<StoredRecipe>(
            sortBy: [SortDescriptor(\.title)]
        )
        return try modelContext.fetch(descriptor).compactMap { stored in
            guard let revision = stored.conflictRemoteRevision else {
                return nil
            }
            return RecipeSyncConflict(
                localRecipe: try decodeRecipe(stored),
                remoteRecipe: try stored.conflictRemotePayload.map {
                    try decoder.decode(Recipe.self, from: $0)
                },
                remoteRevision: revision
            )
        }
    }

    func resolveSyncConflict(
        recipeID: UUID,
        resolution: RecipeSyncConflictResolution
    ) throws {
        guard
            let stored = try storedRecipe(id: recipeID),
            let remoteRevision = stored.conflictRemoteRevision
        else {
            return
        }

        switch resolution {
        case .keepLocal:
            stored.serverRevision = remoteRevision
            clearConflict(on: stored)
        case .acceptRemote:
            if let payload = stored.conflictRemotePayload {
                let remote = try decoder.decode(Recipe.self, from: payload)
                apply(remote, payload: payload, to: stored)
                stored.serverRevision = remoteRevision
                stored.pendingMutationKey = nil
                stored.isTombstoned = false
                clearConflict(on: stored)
            } else {
                modelContext.delete(stored)
            }
        }
        try modelContext.save()
    }

    func syncConflictCount() throws -> Int {
        try modelContext.fetch(FetchDescriptor<StoredRecipe>())
            .count { $0.conflictRemoteRevision != nil }
    }

    func applySyncPage(_ page: RemoteSyncPageDTO) throws {
        for change in page.changes {
            let stored = try storedRecipe(id: change.recipeID)
            if let stored, stored.pendingMutationKey != nil {
                if let remote = change.recipe {
                    stored.conflictRemotePayload = try encoder.encode(
                        remote.recipe()
                    )
                }
                stored.conflictRemoteRevision = change.recipeRevision
                continue
            }
            if let stored,
               change.recipeRevision <= stored.serverRevision {
                continue
            }
            switch change.kind {
            case .upsert:
                guard let remote = change.recipe else {
                    throw RemoteContractError.invalidImportStatus
                }
                let recipe = try remote.recipe()
                let payload = try encoder.encode(recipe)
                if let stored {
                    apply(recipe, payload: payload, to: stored)
                    stored.serverRevision = remote.revision
                    stored.isTombstoned = false
                    stored.conflictRemotePayload = nil
                    stored.conflictRemoteRevision = nil
                } else {
                    modelContext.insert(
                        makeStoredRecipe(
                            recipe,
                            payload: payload,
                            serverRevision: remote.revision
                        )
                    )
                }
            case .delete:
                if let stored {
                    modelContext.delete(stored)
                }
            }
        }
        try modelContext.save()
    }

    func reconcileServerSnapshot(activeRecipeIDs: Set<UUID>) throws {
        let recipes = try modelContext.fetch(FetchDescriptor<StoredRecipe>())
        for stored in recipes
        where stored.serverRevision > 0
            && stored.pendingMutationKey == nil
            && !activeRecipeIDs.contains(stored.id)
        {
            modelContext.delete(stored)
        }
        try modelContext.save()
    }

    private func decodeRecipe(_ stored: StoredRecipe) throws -> Recipe {
        try decoder.decode(Recipe.self, from: stored.payload)
    }

    private func clearConflict(on stored: StoredRecipe) {
        stored.conflictRemotePayload = nil
        stored.conflictRemoteRevision = nil
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
