import Foundation
import LadleCore
import SwiftData
import XCTest
@testable import Ladle

@MainActor
final class SharedQueueReconcilerTests: XCTestCase {
    func testMapsSharedEnvelopeToImportJobExactlyOnce() throws {
        try withTemporaryQueue { queue in
            let envelope = makeEnvelope()
            try queue.enqueue(envelope)
            let repository = ReconciliationTestRepository()
            let reconciler = SharedQueueReconciler(
                queue: queue,
                repository: repository
            )

            XCTAssertEqual(try reconciler.reconcile(), 1)

            let job = try XCTUnwrap(repository.importJobs.first)
            XCTAssertEqual(job.id, envelope.id)
            XCTAssertEqual(job.sourceURL, envelope.sourceURL)
            XCTAssertEqual(job.source, .instagram)
            XCTAssertEqual(job.createdAt, envelope.createdAt)
            XCTAssertEqual(job.status, .parsing)
            XCTAssertTrue(try queue.pendingEnvelopes().isEmpty)

            XCTAssertEqual(try reconciler.reconcile(), 0)
            XCTAssertEqual(repository.importJobs.count, 1)
            XCTAssertEqual(repository.saveCallCount, 1)
        }
    }

    func testReconcilesEnvelopeIntoSwiftDataExactlyOnce() throws {
        try withTemporaryQueue { queue in
            let envelope = makeEnvelope()
            try queue.enqueue(envelope)
            let configuration = ModelConfiguration(
                isStoredInMemoryOnly: true
            )
            let container = try ModelContainer(
                for: StoredRecipe.self,
                StoredImportJob.self,
                configurations: configuration
            )
            let repository = SwiftDataRecipeRepository(
                modelContext: container.mainContext
            )
            let reconciler = SharedQueueReconciler(
                queue: queue,
                repository: repository
            )

            XCTAssertEqual(try reconciler.reconcile(), 1)
            XCTAssertEqual(try reconciler.reconcile(), 0)

            let jobs = try repository.fetchImportJobs()
            XCTAssertEqual(jobs.count, 1)
            XCTAssertEqual(jobs.first?.id, envelope.id)
            XCTAssertTrue(try queue.pendingEnvelopes().isEmpty)
        }
    }

    func testExistingJobDequeuesCrashRecoveryEnvelopeWithoutSavingAgain() throws {
        try withTemporaryQueue { queue in
            let envelope = makeEnvelope()
            try queue.enqueue(envelope)
            let existing = ImportJob.queued(
                sourceURL: envelope.sourceURL,
                source: .instagram,
                id: envelope.id,
                createdAt: envelope.createdAt
            )
            let repository = ReconciliationTestRepository(
                importJobs: [existing]
            )

            let reconciled = try SharedQueueReconciler(
                queue: queue,
                repository: repository
            )
            .reconcile()

            XCTAssertEqual(reconciled, 0)
            XCTAssertEqual(repository.importJobs, [existing])
            XCTAssertEqual(repository.saveCallCount, 0)
            XCTAssertTrue(try queue.pendingEnvelopes().isEmpty)
        }
    }

    func testPersistenceFailureLeavesEnvelopeQueuedForRetry() throws {
        try withTemporaryQueue { queue in
            let envelope = makeEnvelope()
            try queue.enqueue(envelope)
            let repository = ReconciliationTestRepository()
            repository.shouldFailSavingImport = true
            let reconciler = SharedQueueReconciler(
                queue: queue,
                repository: repository
            )

            XCTAssertThrowsError(try reconciler.reconcile())
            XCTAssertTrue(repository.importJobs.isEmpty)
            XCTAssertEqual(try queue.pendingEnvelopes(), [envelope])

            repository.shouldFailSavingImport = false
            XCTAssertEqual(try reconciler.reconcile(), 1)
            XCTAssertTrue(try queue.pendingEnvelopes().isEmpty)
        }
    }

    private func makeEnvelope() -> SharedImportEnvelope {
        SharedImportEnvelope(
            id: UUID(
                uuidString: "A6D21C91-88ED-4C13-994F-C88D73859B47"
            )!,
            sourceURL: URL(
                string: "https://www.instagram.com/reel/lemon-orzo"
            )!,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    private func withTemporaryQueue(
        _ body: (SharedImportQueue) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try body(SharedImportQueue(directoryURL: directory))
    }
}

@MainActor
private final class ReconciliationTestRepository: RecipeRepository {
    enum Failure: Error {
        case requested
    }

    var importJobs: [ImportJob]
    var shouldFailSavingImport = false
    private(set) var saveCallCount = 0

    init(importJobs: [ImportJob] = []) {
        self.importJobs = importJobs
    }

    func fetchRecipes() throws -> [Recipe] {
        []
    }

    func fetchRecipe(id: UUID) throws -> Recipe? {
        nil
    }

    func save(_ recipe: Recipe) throws {}

    func deleteRecipe(id: UUID) throws {}

    func fetchImportJobs() throws -> [ImportJob] {
        importJobs
    }

    func save(_ importJob: ImportJob) throws {
        saveCallCount += 1
        guard !shouldFailSavingImport else {
            throw Failure.requested
        }
        if let index = importJobs.firstIndex(
            where: { $0.id == importJob.id }
        ) {
            importJobs[index] = importJob
        } else {
            importJobs.append(importJob)
        }
    }

    func seedIfNeeded(
        recipes: [Recipe],
        importJobs: [ImportJob]
    ) throws {}
}
