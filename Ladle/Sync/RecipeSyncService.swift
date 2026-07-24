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

@MainActor
protocol RecipeSyncRepository: AnyObject, Sendable {
    func pendingRecipeMutations() throws -> [PendingRecipeMutation]
    func markUpsertSynced(_ recipe: RemoteRecipeDTO) throws
    func markDeleteSynced(recipeID: UUID) throws
    func preserveConflict(
        localRecipe: Recipe,
        remoteRecipe: RemoteRecipeDTO,
        remoteRevision: Int
    ) throws
    func applySyncPage(_ page: RemoteSyncPageDTO) throws
}

actor RecipeSyncService {
    private struct SyncRun {
        let id: UUID
        let task: Task<Void, Error>
    }

    private struct RecipeMutationRequest: Encodable, Sendable {
        let baseRevision: Int
        let recipe: RemoteRecipeDTO
    }

    private let api: APIClient
    private let repository: any RecipeSyncRepository
    private let cursorStore: any SyncCursorStoring
    private var inFlight: SyncRun?

    init(
        api: APIClient,
        repository: any RecipeSyncRepository,
        cursorStore: any SyncCursorStoring
    ) {
        self.api = api
        self.repository = repository
        self.cursorStore = cursorStore
    }

    func synchronize() async throws {
        if let inFlight {
            return try await inFlight.task.value
        }
        try await startSync()
    }

    func resetAndSynchronize() async throws {
        if let inFlight {
            do {
                try await inFlight.task.value
            } catch {
                try Task.checkCancellation()
            }
        }
        try cursorStore.reset()
        try await startSync()
    }

    private func startSync() async throws {
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
            try await task.value
            finish(runID: runID)
        } catch {
            finish(runID: runID)
            throw error
        }
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
    ) async throws {
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
                    try await repository.markUpsertSynced(response)
                } catch let APIError.remote(error) {
                    guard case let .syncConflict(
                        currentRecipe,
                        currentRevision
                    ) = error.details else {
                        throw APIError.remote(error)
                    }
                    try await repository.preserveConflict(
                        localRecipe: recipe,
                        remoteRecipe: currentRecipe,
                        remoteRevision: currentRevision
                    )
                }
            case let .delete(recipeID, baseRevision):
                try await api.requestWithoutResponse(
                    path:
                        "/v1/recipes/\(recipeID.uuidString)?baseRevision=\(baseRevision)",
                    method: .delete
                )
                try await repository.markDeleteSynced(recipeID: recipeID)
            }
        }

        var cursor = try cursorStore.load()
        while true {
            let page: RemoteSyncPageDTO = try await api.request(
                path: "/v1/recipes/sync?cursor=\(cursor)&limit=100"
            )
            try await repository.applySyncPage(page)
            try cursorStore.save(page.nextCursor)
            cursor = page.nextCursor
            if !page.hasMore {
                break
            }
        }
    }
}
