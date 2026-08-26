import Foundation
import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class RecipeSyncServiceTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testPushesManualCreateAtBaseRevisionZeroThenPulls() async throws {
        let recipe = PreviewFixtures.recipes[0]
        let repository = SyncTestRepository(
            pending: [
                .upsert(recipe: recipe, baseRevision: 0),
            ]
        )
        let cursor = InMemorySyncCursorStore()
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            if request.httpMethod == "PUT" {
                return (
                    Self.response(request),
                    try! Self.fixture(named: "recipe-ready")
                )
            }
            return (
                Self.response(request),
                Self.emptyPage(cursor: 0)
            )
        }
        let service = RecipeSyncService(
            api: makeAPI(),
            repository: repository,
            cursorStore: cursor
        )

        try await service.synchronize()

        XCTAssertEqual(repository.syncedUpserts.count, 1)
        XCTAssertEqual(repository.syncedUpserts.first?.revision, 1)
        XCTAssertEqual(try cursor.load(), 0)
        let put = try XCTUnwrap(
            requests.snapshot.first { $0.httpMethod == "PUT" }
        )
        let body = try JSONSerialization.jsonObject(
            with: URLProtocolStub.bodyData(for: put)
        ) as? [String: Any]
        XCTAssertEqual(body?["baseRevision"] as? Int, 0)
    }

    func testAppliesOrderedUpsertAndTombstoneBeforeAdvancingCursor() async throws {
        let repository = SyncTestRepository()
        let cursor = InMemorySyncCursorStore()
        URLProtocolStub.install { request in
            (
                Self.response(request),
                try! Self.fixture(named: "sync-page")
            )
        }
        let service = RecipeSyncService(
            api: makeAPI(),
            repository: repository,
            cursorStore: cursor
        )

        try await service.synchronize()

        XCTAssertEqual(repository.appliedSequences, [1, 2])
        XCTAssertEqual(try cursor.load(), 2)
    }

    func testConflictPreservesLocalDraftAndCurrentServerRecipe() async throws {
        let local = PreviewFixtures.recipes[0]
        let repository = SyncTestRepository(
            pending: [
                .upsert(recipe: local, baseRevision: 1),
            ]
        )
        URLProtocolStub.install { request in
            if request.httpMethod == "PUT" {
                let errors = try! JSONSerialization.jsonObject(
                    with: Self.fixture(named: "errors")
                ) as! [[String: Any]]
                return (
                    Self.response(request, status: 409),
                    try! JSONSerialization.data(
                        withJSONObject: errors[1]
                    )
                )
            }
            return (
                Self.response(request),
                Self.emptyPage(cursor: 0)
            )
        }
        let service = RecipeSyncService(
            api: makeAPI(),
            repository: repository,
            cursorStore: InMemorySyncCursorStore()
        )

        let result = try await service.synchronize()

        XCTAssertEqual(repository.conflicts.count, 1)
        XCTAssertEqual(repository.conflicts.first?.local, local)
        XCTAssertEqual(
            repository.conflicts.first?.remote.title,
            "Tomato Toast"
        )
        XCTAssertEqual(repository.conflicts.first?.revision, 2)
        XCTAssertEqual(result.conflictCount, 1)
    }

    func testResetWaitsForCurrentRunThenStartsAFullSync() async throws {
        let requestCount = Locked<Int>(0)
        let firstRequestArrived = Locked<Bool>(false)
        let releaseFirstRequest = DispatchSemaphore(value: 0)
        URLProtocolStub.install { request in
            let index = requestCount.withValue { count in
                count += 1
                return count
            }
            if index == 1 {
                firstRequestArrived.withValue { $0 = true }
                _ = releaseFirstRequest.wait(timeout: .now() + 5)
                return (
                    Self.response(request),
                    Self.emptyPage(cursor: 42)
                )
            }
            return (
                Self.response(request),
                Self.emptyPage(cursor: 0)
            )
        }
        let cursor = InMemorySyncCursorStore()
        let service = RecipeSyncService(
            api: makeAPI(),
            repository: SyncTestRepository(),
            cursorStore: cursor
        )
        let first = Task {
            try await service.synchronize()
        }
        while !firstRequestArrived.snapshot {
            await Task.yield()
        }
        let reset = Task {
            try await service.resetAndSynchronize()
        }
        await Task.yield()

        releaseFirstRequest.signal()
        _ = try await first.value
        _ = try await reset.value

        XCTAssertEqual(requestCount.snapshot, 2)
        XCTAssertEqual(try cursor.load(), 0)
    }

    func testExpiredCursorRestartsFromSnapshotAndReconcilesMissingRecipes()
        async throws
    {
        let requestCount = Locked<Int>(0)
        URLProtocolStub.install { request in
            let index = requestCount.withValue {
                $0 += 1
                return $0
            }
            if index == 1 {
                return (
                    Self.response(request, status: 409),
                    try! JSONSerialization.data(withJSONObject: [
                        "error": [
                            "code": "syncResetRequired",
                            "message": "Sync history expired.",
                            "retryable": true,
                            "requestID":
                                "00000000-0000-4000-8000-000000000099",
                        ],
                    ])
                )
            }
            return (
                Self.response(request),
                Self.emptyPage(cursor: 8)
            )
        }
        let cursor = InMemorySyncCursorStore(value: 4)
        let repository = SyncTestRepository()
        let service = RecipeSyncService(
            api: makeAPI(),
            repository: repository,
            cursorStore: cursor
        )

        try await service.synchronize()

        XCTAssertEqual(requestCount.snapshot, 2)
        XCTAssertEqual(try cursor.load(), 8)
        XCTAssertEqual(repository.reconciledSnapshots, [Set<UUID>()])
    }

    private func makeAPI() -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            session: URLProtocolStub.session(),
            tokenStore: InMemoryAuthTokenStore(
                tokens: .fixture(accessToken: "access")
            )
        )
    }

    nonisolated private static func response(
        _ request: URLRequest,
        status: Int = 200
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    nonisolated private static func fixture(named name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(
            contentsOf: root
                .appendingPathComponent("Contracts/Fixtures")
                .appendingPathComponent("\(name).json")
        )
    }

    nonisolated private static func emptyPage(cursor: Int64) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "changes": [],
            "nextCursor": cursor,
            "hasMore": false,
        ])
    }
}

@MainActor
private final class SyncTestRepository: RecipeSyncRepository {
    struct Conflict {
        let local: Recipe
        let remote: RemoteRecipeDTO
        let revision: Int
    }

    var pending: [PendingRecipeMutation]
    private(set) var syncedUpserts: [RemoteRecipeDTO] = []
    private(set) var syncedDeletes: [UUID] = []
    private(set) var appliedSequences: [Int64] = []
    private(set) var conflicts: [Conflict] = []
    private(set) var reconciledSnapshots: [Set<UUID>] = []

    init(pending: [PendingRecipeMutation] = []) {
        self.pending = pending
    }

    func pendingRecipeMutations() throws -> [PendingRecipeMutation] {
        pending
    }

    func markUpsertSynced(_ recipe: RemoteRecipeDTO) throws {
        syncedUpserts.append(recipe)
        pending.removeAll { $0.recipeID == recipe.id }
    }

    func markDeleteSynced(recipeID: UUID) throws {
        syncedDeletes.append(recipeID)
        pending.removeAll { $0.recipeID == recipeID }
    }

    func preserveConflict(
        localRecipe: Recipe,
        remoteRecipe: RemoteRecipeDTO,
        remoteRevision: Int
    ) throws {
        conflicts.append(
            Conflict(
                local: localRecipe,
                remote: remoteRecipe,
                revision: remoteRevision
            )
        )
    }

    func applySyncPage(_ page: RemoteSyncPageDTO) throws {
        appliedSequences.append(contentsOf: page.changes.map(\.sequence))
    }

    func reconcileServerSnapshot(activeRecipeIDs: Set<UUID>) throws {
        reconciledSnapshots.append(activeRecipeIDs)
    }

    func syncConflictCount() throws -> Int {
        conflicts.count
    }
}

private final class InMemorySyncCursorStore:
    SyncCursorStoring,
    @unchecked Sendable
{
    private let value: Locked<Int64>

    init(value: Int64 = 0) {
        self.value = Locked(value)
    }

    func load() throws -> Int64 {
        value.snapshot
    }

    func save(_ cursor: Int64) throws {
        value.withValue { $0 = cursor }
    }

    func reset() throws {
        value.withValue { $0 = 0 }
    }
}
