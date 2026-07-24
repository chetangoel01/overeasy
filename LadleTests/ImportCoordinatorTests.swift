import Foundation
import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class ImportCoordinatorTests: XCTestCase {
    func testSupportedURLPersistsParsingJobAndReadyRecipe() async throws {
        let repository = ImportTestRepository()
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.submit(
            urlText: "https://www.tiktok.com/@ladle/video/ready-green-curry"
        )

        let recipe = try XCTUnwrap(repository.recipes.first)
        XCTAssertEqual(
            coordinator.state,
            .completed(recipeID: recipe.id)
        )
        XCTAssertEqual(recipe.title, "Weeknight Green Curry")
        XCTAssertEqual(repository.importJobs.count, 1)
        XCTAssertEqual(repository.importJobs.first?.status, .ready)
    }

    func testMalformedAndUnsupportedURLsDoNotCreateJobs() async {
        let repository = ImportTestRepository()
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.submit(urlText: "not a link")
        XCTAssertEqual(
            coordinator.state,
            .validationFailed(.invalidURL)
        )

        await coordinator.submit(
            urlText: "https://recipes.example.com/lemon-orzo"
        )
        XCTAssertEqual(
            coordinator.state,
            .validationFailed(.unsupportedSource)
        )
        XCTAssertTrue(repository.importJobs.isEmpty)
    }

    func testDuplicateCanOpenExistingOrImportAnotherCopy() async {
        let duplicateURL = URL(
            string: "https://www.instagram.com/reel/ready-green-curry"
        )!
        let existing = importRecipe(
            title: "Existing Green Curry",
            originalURL: duplicateURL
        )
        let repository = ImportTestRepository(recipes: [existing])
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.submit(urlText: duplicateURL.absoluteString)

        XCTAssertEqual(
            coordinator.state,
            .duplicate(existingRecipeID: existing.id)
        )
        XCTAssertEqual(coordinator.existingDuplicate, existing)
        XCTAssertTrue(repository.importJobs.isEmpty)

        await coordinator.importDuplicateCopy()

        XCTAssertEqual(repository.recipes.count, 2)
        XCTAssertNotEqual(repository.recipes.last?.id, existing.id)
    }

    func testRemoteDuplicateRemovesLocalAdmissionJob() async throws {
        let existing = importRecipe(
            title: "Existing Green Curry",
            originalURL: URL(
                string: "https://www.tiktok.com/@ladle/video/existing"
            )!
        )
        let repository = ImportTestRepository(recipes: [existing])
        let service = ThrowingImportService(
            error: try remoteAPIError(
                code: "duplicateRecipe",
                details: [
                    "existingRecipeID": existing.id.uuidString.lowercased(),
                ]
            )
        )
        let coordinator = ImportCoordinator(
            repository: repository,
            service: service,
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.submit(
            urlText: "https://www.tiktok.com/@ladle/video/duplicate"
        )

        XCTAssertEqual(
            coordinator.state,
            .duplicate(existingRecipeID: existing.id)
        )
        XCTAssertTrue(repository.importJobs.isEmpty)
    }

    func testRemoteGuestLimitRemovesLocalAdmissionJob() async throws {
        let repository = ImportTestRepository()
        let coordinator = ImportCoordinator(
            repository: repository,
            service: ThrowingImportService(
                error: try remoteAPIError(
                    code: "guestRecipeLimitReached"
                )
            ),
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.submit(
            urlText: "https://www.tiktok.com/@ladle/video/limit"
        )

        XCTAssertEqual(coordinator.state, .guestLimit(.limitReached))
        XCTAssertTrue(repository.importJobs.isEmpty)
    }

    func testGuestLimitBlocksNewImportUntilAccountIsCreated() async {
        let repository = ImportTestRepository(
            recipes: (0..<10).map {
                importRecipe(
                    id: UUID(),
                    title: "Recipe \($0)",
                    originalURL: URL(
                        string: "https://example.com/recipe-\($0)"
                    )!
                )
            }
        )
        let accountSession = AccountSession(
            store: ImportTestPreferenceStore()
        )
        accountSession.continueAsGuest()
        let coordinator = makeCoordinator(
            repository: repository,
            accountSession: accountSession
        )

        await coordinator.submit(
            urlText: "https://youtu.be/ready-green-curry"
        )

        XCTAssertEqual(
            coordinator.state,
            .guestLimit(.limitReached)
        )
        XCTAssertTrue(repository.importJobs.isEmpty)

        accountSession.createFreeAccount()
        await coordinator.continueAfterGuestPrompt()

        XCTAssertEqual(repository.recipes.count, 11)
        XCTAssertEqual(repository.importJobs.first?.status, .ready)
    }

    func testNeedsReviewOutcomePersistsRecipeAndReviewState() async throws {
        let repository = ImportTestRepository()
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.submit(
            urlText: "https://www.instagram.com/reel/needs-review-ragu"
        )

        let recipe = try XCTUnwrap(repository.recipes.first)
        XCTAssertEqual(
            coordinator.state,
            .needsReview(recipeID: recipe.id)
        )
        XCTAssertEqual(recipe.reviewStatus, .needsReview)
        XCTAssertEqual(repository.importJobs.first?.status, .needsReview)
    }

    func testManualRecipeCanContinueThroughTenthGuestPrompt() async {
        let repository = ImportTestRepository(
            recipes: (0..<9).map {
                importRecipe(
                    title: "Recipe \($0)",
                    originalURL: URL(
                        string: "https://example.com/recipe-\($0)"
                    )!
                )
            }
        )
        let accountSession = AccountSession(
            store: ImportTestPreferenceStore()
        )
        accountSession.continueAsGuest()
        let coordinator = makeCoordinator(
            repository: repository,
            accountSession: accountSession
        )

        await coordinator.createManualRecipe(
            title: "Grandma’s Soup",
            details: "Simmer gently."
        )

        XCTAssertEqual(
            coordinator.state,
            .guestLimit(.allowWithAccountPrompt)
        )

        await coordinator.continueAfterGuestPrompt()

        XCTAssertEqual(repository.recipes.count, 10)
        XCTAssertEqual(repository.recipes.last?.title, "Grandma’s Soup")
    }

    func testRetryStoresCorrectionNotesAndCanRecoverParserFailure() async throws {
        let failed = try failedJob(slug: "parser-failed-soup")
        let repository = ImportTestRepository(importJobs: [failed])
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.retry(
            jobID: failed.id,
            correctionNotes: "The sauce uses one cup of stock."
        )

        XCTAssertEqual(repository.importJobs.first?.status, .ready)
        XCTAssertEqual(
            repository.importJobs.first?.correctionNotes,
            "The sauce uses one cup of stock."
        )
        XCTAssertEqual(repository.importJobs.first?.retryCount, 1)
        XCTAssertEqual(repository.recipes.count, 1)
    }

    func testPastedDetailsRecoverPrivateImportWithoutDiscardingLink() async throws {
        let failed = try failedJob(slug: "private-family-pasta")
        let repository = ImportTestRepository(importJobs: [failed])
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.retry(
            jobID: failed.id,
            pastedRecipeText: """
            Family Pasta
            1 pound pasta
            Simmer with tomato sauce.
            """
        )

        XCTAssertEqual(repository.importJobs.first?.status, .ready)
        XCTAssertEqual(
            repository.importJobs.first?.sourceURL,
            failed.sourceURL
        )
        XCTAssertEqual(repository.recipes.first?.title, "Family Pasta")
    }

    func testFailedReimportRetryKeepsCurrentRecipeUntouched() async throws {
        let current = importRecipe(
            title: "Current Usable Recipe",
            originalURL: URL(string: "https://example.com/current")!
        )
        let reimporting = ImportJob.reimporting(
            sourceURL: URL(
                string: "https://www.tiktok.com/@ladle/video/parser-failed-update"
            )!,
            source: .tiktok,
            currentRecipeID: current.id,
            candidateRecipeID: UUID()
        )
        let failed = try reimporting.transitioning(
            to: .failed(.parserUnavailable)
        )
        let repository = ImportTestRepository(
            recipes: [current],
            importJobs: [failed]
        )
        let coordinator = ImportCoordinator(
            repository: repository,
            service: FixedImportService(
                outcome: .failed(.parserUnavailable)
            ),
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.retry(jobID: failed.id)

        XCTAssertEqual(repository.recipes, [current])
        XCTAssertEqual(
            repository.importJobs.first?.currentRecipeID,
            current.id
        )
        XCTAssertNil(repository.importJobs.first?.candidateRecipeID)
        XCTAssertEqual(
            repository.importJobs.first?.status,
            .failed(.parserUnavailable)
        )
    }

    func testRelaunchResumesPersistedRemoteJobWithoutResubmitting() async throws {
        var pending = ImportJob.queued(
            sourceURL: URL(
                string: "https://youtu.be/resume-this-import"
            )!,
            source: .youtube
        )
        pending.remoteJobID = pending.id.uuidString
        let recipe = importRecipe(
            id: pending.id,
            title: "Resumed Recipe",
            originalURL: pending.sourceURL
        )
        let service = ScriptedImportService(
            statuses: [
                ImportServiceUpdate(
                    remoteJobID: pending.id.uuidString,
                    progress: .ready(recipe)
                ),
            ]
        )
        let repository = ImportTestRepository(importJobs: [pending])
        let coordinator = ImportCoordinator(
            repository: repository,
            service: service,
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.resumePendingImports()

        let submitCount = await service.submitCount
        let statusCount = await service.statusCount
        XCTAssertEqual(submitCount, 0)
        XCTAssertEqual(statusCount, 1)
        XCTAssertEqual(repository.recipes, [recipe])
        XCTAssertEqual(repository.importJobs.first?.status, .ready)
    }

    func testCancellationStopsPollingAndLeavesDurableJobParsing() async throws {
        let service = SlowPollingImportService()
        let repository = ImportTestRepository()
        let coordinator = ImportCoordinator(
            repository: repository,
            service: service,
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )
        let task = Task {
            await coordinator.submit(
                urlText: "https://youtu.be/slow-remote-import"
            )
        }

        while repository.importJobs.first?.remoteJobID == nil {
            await Task.yield()
        }
        task.cancel()
        await task.value

        XCTAssertEqual(repository.importJobs.first?.status, .parsing)
        XCTAssertNotNil(repository.importJobs.first?.remoteJobID)
        XCTAssertEqual(coordinator.state, .idle)
    }

    private func makeCoordinator(
        repository: ImportTestRepository,
        accountSession: AccountSession = AccountSession(
            store: ImportTestPreferenceStore()
        )
    ) -> ImportCoordinator {
        ImportCoordinator(
            repository: repository,
            service: DemoImportService(),
            accountSession: accountSession,
            clock: ImmediateImportClock()
        )
    }

    private func failedJob(slug: String) throws -> ImportJob {
        try ImportJob.queued(
            sourceURL: URL(
                string: "https://www.tiktok.com/@ladle/video/\(slug)"
            )!,
            source: .tiktok
        )
        .transitioning(to: .failed(.parserUnavailable))
    }
}

private struct ImmediateImportClock: ImportClock {
    func sleep(for duration: Duration) async throws {}
}

private actor ScriptedImportService: ImportService {
    private var statuses: [ImportServiceUpdate]
    private(set) var submitCount = 0
    private(set) var statusCount = 0

    init(statuses: [ImportServiceUpdate]) {
        self.statuses = statuses
    }

    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        submitCount += 1
        return ImportServiceUpdate(
            remoteJobID: job.id.uuidString,
            progress: .parsing
        )
    }

    func status(remoteJobID: String) async throws -> ImportServiceUpdate {
        statusCount += 1
        return statuses.removeFirst()
    }

    func retry(
        remoteJobID: String,
        correctionNotes: String?,
        pastedRecipeText: String?
    ) async throws -> ImportServiceUpdate {
        statuses.removeFirst()
    }
}

private actor SlowPollingImportService: ImportService {
    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(
            remoteJobID: job.id.uuidString,
            progress: .parsing
        )
    }

    func status(remoteJobID: String) async throws -> ImportServiceUpdate {
        try await Task.sleep(for: .seconds(30))
        return ImportServiceUpdate(
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
            progress: .parsing
        )
    }
}

private actor FixedImportService: ImportService {
    let outcome: ImportServiceProgress

    init(outcome: ImportServiceProgress) {
        self.outcome = outcome
    }

    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(
            remoteJobID: job.id.uuidString,
            progress: outcome
        )
    }

    func status(remoteJobID: String) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(remoteJobID: remoteJobID, progress: outcome)
    }

    func retry(
        remoteJobID: String,
        correctionNotes: String?,
        pastedRecipeText: String?
    ) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(remoteJobID: remoteJobID, progress: outcome)
    }
}

private actor ThrowingImportService: ImportService {
    let error: APIError

    init(error: APIError) {
        self.error = error
    }

    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        throw error
    }

    func status(remoteJobID: String) async throws -> ImportServiceUpdate {
        throw error
    }

    func retry(
        remoteJobID: String,
        correctionNotes: String?,
        pastedRecipeText: String?
    ) async throws -> ImportServiceUpdate {
        throw error
    }
}

@MainActor
private final class ImportTestRepository: RecipeRepository {
    var recipes: [Recipe]
    var importJobs: [ImportJob]

    init(
        recipes: [Recipe] = [],
        importJobs: [ImportJob] = []
    ) {
        self.recipes = recipes
        self.importJobs = importJobs
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

    func deleteImportJob(id: UUID) throws {
        importJobs.removeAll { $0.id == id }
    }

    func seedIfNeeded(
        recipes: [Recipe],
        importJobs: [ImportJob]
    ) throws {}
}

private func remoteAPIError(
    code: String,
    details: [String: String]? = nil
) throws -> APIError {
    var error: [String: Any] = [
        "code": code,
        "message": "Remote admission rejected the import.",
        "retryable": false,
        "requestID": UUID().uuidString.lowercased(),
    ]
    if let details {
        error["details"] = details
    }
    let data = try JSONSerialization.data(
        withJSONObject: ["error": error]
    )
    let envelope = try RemoteContractJSON.decoder().decode(
        RemoteErrorEnvelope.self,
        from: data
    )
    return .remote(envelope.error)
}

private final class ImportTestPreferenceStore: PreferenceStoring {
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

private func importRecipe(
    id: UUID = UUID(),
    title: String,
    originalURL: URL
) -> Recipe {
    Recipe(
        id: id,
        title: title,
        source: .other,
        originalURL: originalURL,
        servings: 4
    )
}
