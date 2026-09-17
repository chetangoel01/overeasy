import Foundation
import LadleCore

enum PendingRecipeMutation: Equatable, Sendable {
    case upsert(recipe: Recipe, baseRevision: Int)
    case delete(recipeID: UUID, baseRevision: Int)

    var recipeID: UUID {
        switch self {
        case let .upsert(recipe, _):
            recipe.id
        case let .delete(recipeID, _):
            recipeID
        }
    }
}

struct RecipeSyncResult: Equatable, Sendable {
    let conflictCount: Int
}

@MainActor
protocol RecipeSyncRepository: AnyObject, Sendable {
    func pendingRecipeMutations() throws -> [PendingRecipeMutation]
    func markUpsertSynced(_ recipe: RemoteRecipeDTO, pushed: Recipe) throws
    func markDeleteSynced(recipeID: UUID) throws
    func preserveConflict(
        localRecipeID: UUID,
        remoteRecipe: RemoteRecipeDTO,
        remoteRevision: Int
    ) throws
    func applySyncPage(_ page: RemoteSyncPageDTO) throws
    func reconcileServerSnapshot(activeRecipeIDs: Set<UUID>) throws
    func syncConflictCount() throws -> Int
}

actor RecipeSyncService {
    private struct SyncRun {
        let id: UUID
        let task: Task<RecipeSyncResult, Error>
    }

    private struct RecipeMutationRequest: Encodable, Sendable {
        let baseRevision: Int
        let recipe: RemoteRecipeDTO
    }

    private let api: APIClient
    private let repository: any RecipeSyncRepository
    private let cursorStore: any SyncCursorStoring
    private var inFlight: SyncRun?
    /// Recipes synced before the server named their source hold no
    /// `sourceID`, and an incremental pull never serves them again. Until a
    /// pull from the beginning has delivered one, the first sync of each
    /// launch starts there. Replaying is safe to repeat: a row the device
    /// already holds takes the server's copy only while it has no pending
    /// edit, and a server that does not send the field yet changes nothing,
    /// this flag included — so the pull is still owed once it does.
    private var replaysLogForSourceIDs: Bool

    init(
        api: APIClient,
        repository: any RecipeSyncRepository,
        cursorStore: any SyncCursorStoring
    ) {
        self.api = api
        self.repository = repository
        self.cursorStore = cursorStore
        replaysLogForSourceIDs = !cursorStore.hasLearnedSourceIDs
    }

    @discardableResult
    func synchronize() async throws -> RecipeSyncResult {
        if let inFlight {
            return try await inFlight.task.value
        }
        if replaysLogForSourceIDs {
            replaysLogForSourceIDs = false
            try cursorStore.reset()
        }
        return try await startSync()
    }

    @discardableResult
    func resetAndSynchronize() async throws -> RecipeSyncResult {
        if let inFlight {
            do {
                _ = try await inFlight.task.value
            } catch {
                try Task.checkCancellation()
            }
        }
        try cursorStore.reset()
        replaysLogForSourceIDs = false
        return try await startSync()
    }

    private func startSync() async throws -> RecipeSyncResult {
        let runID = UUID()
        let api = api
        let repository = repository
        let cursorStore = cursorStore
        let task = Task {
            try await Self.performSync(
                api: api,
                repository: repository,
                cursorStore: cursorStore
            )
        }
        inFlight = SyncRun(id: runID, task: task)
        do {
            let result = try await task.value
            finish(runID: runID)
            return result
        } catch {
            finish(runID: runID)
            throw error
        }
    }

    /// Cancels the run in flight and waits for it to unwind.
    ///
    /// Sign-out wipes the local store, so it must know that no pulled page can
    /// still be written into it. Returning before the run drains would leave
    /// exactly that window open.
    func cancelActiveSync() async {
        guard let run = inFlight else {
            return
        }
        inFlight = nil
        run.task.cancel()
        _ = try? await run.task.value
    }

    private func finish(runID: UUID) {
        guard inFlight?.id == runID else {
            return
        }
        inFlight = nil
    }

    private static func performSync(
        api: APIClient,
        repository: any RecipeSyncRepository,
        cursorStore: any SyncCursorStoring
    ) async throws -> RecipeSyncResult {
        let mutations = try await repository.pendingRecipeMutations()
        for mutation in mutations {
            try Task.checkCancellation()
            switch mutation {
            case let .upsert(recipe, baseRevision):
                do {
                    let response: RemoteRecipeDTO = try await api.request(
                        path: "/v1/recipes/\(recipe.id.uuidString)",
                        method: .put,
                        body: RecipeMutationRequest(
                            baseRevision: baseRevision,
                            recipe: RemoteRecipeDTO(
                                recipe: recipe,
                                revision: max(baseRevision, 1)
                            )
                        )
                    )
                    try await repository.markUpsertSynced(
                        response,
                        pushed: recipe
                    )
                } catch let APIError.remote(error) {
                    guard case let .syncConflict(
                        currentRecipe,
                        currentRevision
                    ) = error.details else {
                        throw APIError.remote(error)
                    }
                    try await repository.preserveConflict(
                        localRecipeID: recipe.id,
                        remoteRecipe: currentRecipe,
                        remoteRevision: currentRevision
                    )
                }
            case let .delete(recipeID, baseRevision):
                do {
                    try await api.requestWithoutResponse(
                        path:
                            "/v1/recipes/\(recipeID.uuidString)?baseRevision=\(baseRevision)",
                        method: .delete
                    )
                    try await repository.markDeleteSynced(recipeID: recipeID)
                } catch let APIError.remote(error) {
                    // Without this the rejected delete stays pending forever
                    // and every later sync throws here, before the pull.
                    guard case let .syncConflict(
                        currentRecipe,
                        currentRevision
                    ) = error.details else {
                        throw APIError.remote(error)
                    }
                    try await repository.preserveConflict(
                        localRecipeID: recipeID,
                        remoteRecipe: currentRecipe,
                        remoteRevision: currentRevision
                    )
                }
            }
        }

        var cursor = try cursorStore.load()
        var startedFromBeginning = cursor == 0
        var snapshotRestarted = false
        var activeRecipeIDs = Set<UUID>()
        while true {
            let page: RemoteSyncPageDTO
            do {
                page = try await api.request(
                    path: "/v1/recipes/sync?cursor=\(cursor)&limit=100"
                )
            } catch let APIError.remote(error)
                where error.code == .syncResetRequired && cursor > 0
            {
                try cursorStore.reset()
                cursor = 0
                startedFromBeginning = true
                snapshotRestarted = true
                activeRecipeIDs.removeAll(keepingCapacity: true)
                continue
            }
            if snapshotRestarted {
                for change in page.changes {
                    switch change.kind {
                    case .upsert:
                        activeRecipeIDs.insert(change.recipeID)
                    case .delete:
                        activeRecipeIDs.remove(change.recipeID)
                    }
                }
            }
            try Task.checkCancellation()
            try await repository.applySyncPage(page)
            // Only a walk from the beginning counts: a `sourceID` on an
            // incremental page says the server sends them, not that the
            // recipes already on this device have been served again.
            if startedFromBeginning,
               page.changes.contains(where: { $0.recipe?.sourceID != nil }) {
                cursorStore.markSourceIDsLearned()
            }
            try Task.checkCancellation()
            try cursorStore.save(page.nextCursor)
            cursor = page.nextCursor
            if !page.hasMore {
                if snapshotRestarted {
                    try await repository.reconcileServerSnapshot(
                        activeRecipeIDs: activeRecipeIDs
                    )
                }
                break
            }
        }
        let conflictCount = try await repository.syncConflictCount()
        return RecipeSyncResult(conflictCount: conflictCount)
    }
}

extension RecipeSyncService: SessionWriter {
    func quiesceForSignOut() async {
        await cancelActiveSync()
    }
}
