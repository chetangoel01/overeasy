import Foundation
import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class ReimportSafetyTests: XCTestCase {
    func testCurrentRecipeRemainsUsableUntilReadyCandidateSucceeds() async throws {
        let current = PreviewFixtures.recipes[1]
        let repository = ReimportTestRepository(recipes: [current])
        let clock = GateImportClock()
        let coordinator = ImportCoordinator(
            repository: repository,
            service: CandidateImportService(result: .ready),
            accountSession: AccountSession(
                store: ReimportTestPreferenceStore()
            ),
            clock: clock
        )

        let task = Task {
            await coordinator.reimport(
                recipe: current,
                correctionNotes: "Keep the lemon bright."
            )
        }
        await waitUntilImporting(coordinator)

        let parsingJob = try XCTUnwrap(repository.importJobs.first)
        let candidateID = try XCTUnwrap(parsingJob.candidateRecipeID)
        XCTAssertEqual(
            try repository.fetchRecipe(id: current.id),
            current
        )
        XCTAssertNil(try repository.fetchRecipe(id: candidateID))
        XCTAssertEqual(parsingJob.currentRecipeID, current.id)
        XCTAssertEqual(
            parsingJob.correctionNotes,
            "Keep the lemon bright."
        )

        await clock.release()
        await task.value

        XCTAssertNil(try repository.fetchRecipe(id: current.id))
        let replacement = try XCTUnwrap(
            repository.fetchRecipe(id: candidateID)
        )
        XCTAssertEqual(replacement.title, "Re-imported Lemon Orzo")
        XCTAssertEqual(
            coordinator.state,
            .completed(recipeID: candidateID)
        )
        XCTAssertEqual(repository.importJobs.first?.status, .ready)
        XCTAssertEqual(
            repository.importJobs.first?.currentRecipeID,
            candidateID
        )
    }

    func testFailedCandidateKeepsCurrentRecipeAndDiscardsCandidateID() async throws {
        let current = PreviewFixtures.recipes[1]
        let repository = ReimportTestRepository(recipes: [current])
        let coordinator = ImportCoordinator(
            repository: repository,
            service: CandidateImportService(
                result: .failed(.parserUnavailable)
            ),
            accountSession: AccountSession(
                store: ReimportTestPreferenceStore()
            ),
            clock: ReimportImmediateClock()
        )

        await coordinator.reimport(
            recipe: current,
            correctionNotes: "The creator speaks quickly."
        )

        XCTAssertEqual(
            try repository.fetchRecipe(id: current.id),
            current
        )
        XCTAssertEqual(repository.recipes, [current])
        XCTAssertEqual(
            repository.importJobs.first?.status,
            .failed(.parserUnavailable)
        )
        XCTAssertEqual(
            repository.importJobs.first?.currentRecipeID,
            current.id
        )
        XCTAssertNil(repository.importJobs.first?.candidateRecipeID)
        XCTAssertNil(coordinator.completedRecipe)
    }

    func testNeedsReviewCandidateDoesNotReplaceOrExposeCurrentRecipe() async throws {
        let current = PreviewFixtures.recipes[1]
        let repository = ReimportTestRepository(recipes: [current])
        let coordinator = ImportCoordinator(
            repository: repository,
            service: CandidateImportService(result: .needsReview),
            accountSession: AccountSession(
                store: ReimportTestPreferenceStore()
            ),
            clock: ReimportImmediateClock()
        )

        await coordinator.reimport(recipe: current)

        XCTAssertEqual(repository.recipes, [current])
        XCTAssertEqual(
            try repository.fetchRecipe(id: current.id),
            current
        )
        XCTAssertEqual(repository.importJobs.first?.status, .needsReview)
        XCTAssertNotNil(repository.importJobs.first?.candidateRecipeID)
    }

    func testRetryingFailedReimportUsesFreshCandidateAndReplacesCurrent() async throws {
        let current = PreviewFixtures.recipes[1]
        let repository = ReimportTestRepository(recipes: [current])
        var failedJob = ImportJob.reimporting(
            sourceURL: current.originalURL,
            source: current.source,
            currentRecipeID: current.id,
            candidateRecipeID: UUID()
        )
        failedJob.correctionNotes = "Keep the lemon bright."
        failedJob = try failedJob.transitioning(
            to: .failed(.parserUnavailable)
        )
        try repository.save(failedJob)
        let coordinator = ImportCoordinator(
            repository: repository,
            service: CandidateImportService(result: .ready),
            accountSession: AccountSession(
                store: ReimportTestPreferenceStore()
            ),
            clock: ReimportImmediateClock()
        )

        await coordinator.retry(
            jobID: failedJob.id,
            correctionNotes: "Use the corrected timings."
        )

        let retriedJob = try XCTUnwrap(repository.importJobs.first)
        let replacementID = try XCTUnwrap(retriedJob.currentRecipeID)
        XCTAssertNotEqual(replacementID, current.id)
        XCTAssertNil(try repository.fetchRecipe(id: current.id))
        XCTAssertEqual(
            try repository.fetchRecipe(id: replacementID)?.title,
            "Re-imported Lemon Orzo"
        )
        XCTAssertEqual(retriedJob.status, .ready)
        XCTAssertEqual(retriedJob.retryCount, 1)
        XCTAssertEqual(
            retriedJob.correctionNotes,
            "Use the corrected timings."
        )
        XCTAssertEqual(
            coordinator.state,
            .completed(recipeID: replacementID)
        )
    }

    private func waitUntilImporting(
        _ coordinator: ImportCoordinator
    ) async {
        for _ in 0..<20 {
            if coordinator.isImporting {
                return
            }
            await Task.yield()
        }
        XCTFail("Re-import did not enter the parsing state")
    }
}

private struct CandidateImportService: ImportService {
    enum Result: Sendable {
        case ready
        case needsReview
        case failed(ImportFailure)
    }

    let result: Result

    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(
            remoteJobID: job.id.uuidString,
            progress: progress(for: job)
        )
    }

    func status(remoteJobID: String) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(
            remoteJobID: remoteJobID,
            progress: .failed(.networkUnavailable)
        )
    }

    func retry(
        remoteJobID: String,
        correctionNotes: String?,
        pastedRecipeText: String?
    ) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(
            remoteJobID: remoteJobID,
            progress: .failed(.networkUnavailable)
        )
    }

    private func progress(
        for job: ImportJob
    ) -> ImportServiceProgress {
        switch result {
        case .ready:
            return .ready(candidate(for: job, needsReview: false))
        case .needsReview:
            return .needsReview(candidate(for: job, needsReview: true))
        case let .failed(reason):
            return .failed(reason)
        }
    }

    private func candidate(
        for job: ImportJob,
        needsReview: Bool
    ) -> Recipe {
        Recipe(
            id: job.candidateRecipeID ?? job.id,
            title: "Re-imported Lemon Orzo",
            source: job.source,
            originalURL: job.sourceURL,
            servings: 4,
            reviewStatus: needsReview ? .needsReview : .ready,
            createdAt: job.createdAt,
            updatedAt: job.updatedAt
        )
    }
}

private actor GateImportClock: ImportClock {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func sleep(for duration: Duration) async throws {
        if !isReleased {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        try Task.checkCancellation()
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private struct ReimportImmediateClock: ImportClock {
    func sleep(for duration: Duration) async throws {}
}

@MainActor
private final class ReimportTestRepository: RecipeRepository {
    var recipes: [Recipe]
    var importJobs: [ImportJob] = []

    init(recipes: [Recipe]) {
        self.recipes = recipes
    }

    func fetchRecipes() throws -> [Recipe] {
        recipes
    }

    func fetchRecipe(id: UUID) throws -> Recipe? {
        recipes.first { $0.id == id }
    }

    func save(_ recipe: Recipe) throws {
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
    }

    func deleteRecipe(id: UUID) throws {
        recipes.removeAll { $0.id == id }
    }

    func fetchImportJobs() throws -> [ImportJob] {
        importJobs
    }

    func save(_ importJob: ImportJob) throws {
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

private final class ReimportTestPreferenceStore: PreferenceStoring {
    private var values: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}
