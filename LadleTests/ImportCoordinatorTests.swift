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
        XCTAssertEqual(
            coordinator.operation,
            .importJob(try XCTUnwrap(repository.importJobs.first?.id))
        )
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

        // The backend confirms the merged account; the sheet then resumes
        // the blocked import.
        accountSession.applyRemoteUserKind("apple")
        await coordinator.continueAfterGuestPrompt()

        XCTAssertEqual(repository.recipes.count, 11)
        XCTAssertEqual(repository.importJobs.first?.status, .ready)
    }

    func testGuestLimitAccountCreationWithoutBackendConfirmationLeavesTheGuestCapped() async {
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
        XCTAssertEqual(coordinator.state, .guestLimit(.limitReached))

        // The guest-limit sheet's create-account buttons drive the real
        // sign-in flow; here the provider fails before the backend ever
        // confirms an account.
        let tokenStore = InMemoryAuthTokenStore(
            tokens: .fixture(accessToken: "guest-access")
        )
        let flow = AccountSignInFlow(
            accountSession: accountSession,
            authClient: AuthClient(
                api: APIClient(
                    baseURL: URL(string: "https://api.ladle.test")!,
                    session: URLProtocolStub.session(),
                    tokenStore: tokenStore
                ),
                tokenStore: tokenStore,
                accountSession: accountSession,
                installationIdentity: InstallationIdentity(
                    store: ImportTestPreferenceStore()
                )
            ),
            googleSignIn: FailingGoogleSignInProvider(),
            onAuthenticated: {
                await coordinator.continueAfterGuestPrompt()
            }
        )
        await flow.signInWithGoogle()

        XCTAssertEqual(
            accountSession.state,
            .guest,
            "No backend confirmed an account, so the device must stay a guest"
        )
        XCTAssertEqual(
            accountSession.saveDecision(savedRecipeCount: 10),
            .limitReached,
            "A guest without a confirmed account must stay capped at 10"
        )
        XCTAssertEqual(
            repository.recipes.count,
            10,
            "The 11th recipe must not save without a real account"
        )
        XCTAssertEqual(
            coordinator.state,
            .guestLimit(.limitReached),
            "The blocked import must stay on the limit sheet, not proceed"
        )
        XCTAssertNotNil(
            flow.failure,
            "The user must see why account creation did not happen"
        )
        XCTAssertFalse(
            flow.isAuthenticating,
            "The sheet must stay interactive for another attempt"
        )
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

    func testPersistedReimportReviewDoesNotBlockAnotherImport() async throws {
        let current = importRecipe(
            title: "Current Recipe",
            originalURL: URL(
                string: "https://www.instagram.com/reel/current-recipe"
            )!
        )
        let repository = ImportTestRepository(recipes: [current])
        let coordinator = ImportCoordinator(
            repository: repository,
            service: ContextualNeedsReviewImportService(),
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.reimport(recipe: current)
        XCTAssertTrue(coordinator.operation?.isReimport == true)
        XCTAssertEqual(repository.importJobs.count, 1)

        coordinator.prepareForNewImport()
        await coordinator.submit(
            urlText: "https://www.tiktok.com/@ladle/video/another-recipe"
        )

        XCTAssertEqual(repository.importJobs.count, 2)
        XCTAssertEqual(
            repository.importJobs.filter { $0.status == .needsReview }.count,
            2
        )
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

    func testConfirmedCancellationTerminatesRemoteAndRemovesDurableJob() async throws {
        let service = CancellablePollingImportService()
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
                urlText: "https://youtu.be/cancel-this-import"
            )
        }

        while repository.importJobs.first?.remoteJobID == nil {
            await Task.yield()
        }
        let jobID = try XCTUnwrap(repository.importJobs.first?.id)

        await coordinator.cancelImport(jobID: jobID)
        await task.value

        XCTAssertTrue(repository.importJobs.isEmpty)
        XCTAssertEqual(coordinator.state, .idle)
        let cancelCount = await service.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testCancelDuringRacingStatusResponseDoesNotResurrectTheJob() async throws {
        // The status response lands in the same instant the user cancels:
        // the poll resumes with a successful update after the durable row
        // was already deleted. Nothing may save that job back. (#30)
        let service = RacingStatusImportService()
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
                urlText: "https://youtu.be/cancel-races-response"
            )
        }
        var polling = false
        while !polling {
            polling = await service.statusStarted
            await Task.yield()
        }
        let jobID = try XCTUnwrap(repository.importJobs.first?.id)

        await coordinator.cancelImport(jobID: jobID)
        await task.value

        XCTAssertTrue(
            repository.importJobs.isEmpty,
            "The cancelled job was saved back: \(repository.importJobs)"
        )
        XCTAssertTrue(repository.recipes.isEmpty)
        XCTAssertEqual(coordinator.state, .idle)
        let cancelCount = await service.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testCancelWhileRequestFailsInFlightDoesNotResurrectTheJobAsFailed() async throws {
        // Cancellation makes the in-flight request fail. However that
        // failure is typed, it must not repersist the deleted row as a
        // failed offline import. (#30, #31)
        let service = TransportOnCancelPollingImportService()
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
                urlText: "https://youtu.be/cancel-fails-request"
            )
        }
        var polling = false
        while !polling {
            polling = await service.statusStarted
            await Task.yield()
        }
        let jobID = try XCTUnwrap(repository.importJobs.first?.id)

        await coordinator.cancelImport(jobID: jobID)
        await task.value

        XCTAssertTrue(
            repository.importJobs.isEmpty,
            "The cancelled job was saved back: \(repository.importJobs)"
        )
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testTaskTeardownDuringNetworkCallLeavesJobParsingInsteadOfFailed() async throws {
        // Ordinary task teardown (scene change, sheet dismissal) cancels
        // the awaiting task mid-request. The job was healthy; it must stay
        // durably .parsing for the next resume, not flip to failed. (#31)
        let service = TransportOnCancelPollingImportService()
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
                urlText: "https://youtu.be/torn-down-mid-poll"
            )
        }
        var polling = false
        while !polling {
            polling = await service.statusStarted
            await Task.yield()
        }

        task.cancel()
        await task.value

        XCTAssertEqual(repository.importJobs.first?.status, .parsing)
        XCTAssertEqual(coordinator.state, .idle)
        let cancelCount = await service.cancelCount
        XCTAssertEqual(
            cancelCount,
            0,
            "Task teardown is not user cancellation and must not cancel the remote job"
        )
    }

    func testResumeWhileForegroundImportPollsLeavesItsOperationAndStateAlone() async throws {
        // sceneBecameActive reconciles a shared link into job B and resumes
        // pending imports while the user's import A is still polling in the
        // sheet. Resume must neither join A's task nor steal its state. (#32)
        let service = GatedImportService()
        let repository = ImportTestRepository()
        let coordinator = ImportCoordinator(
            repository: repository,
            service: service,
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )
        let submitTask = Task {
            await coordinator.submit(
                urlText: "https://youtu.be/foreground-import"
            )
        }
        while repository.importJobs.first?.remoteJobID == nil {
            await Task.yield()
        }
        let jobA = try XCTUnwrap(repository.importJobs.first)
        let recipeA = importRecipe(
            title: "Foreground Recipe",
            originalURL: jobA.sourceURL
        )
        await service.setRecipe(recipeA, forJob: jobA.id.uuidString)

        var jobB = ImportJob.queued(
            sourceURL: URL(string: "https://youtu.be/background-share")!,
            source: .youtube
        )
        jobB.remoteJobID = jobB.id.uuidString.lowercased()
        try repository.save(jobB)
        let recipeB = importRecipe(
            title: "Background Recipe",
            originalURL: jobB.sourceURL
        )
        await service.setRecipe(recipeB, forJob: jobB.id.uuidString)
        await service.release(jobB.id.uuidString)

        let resumeFinished = Locked(false)
        let resumeTask = Task {
            await coordinator.resumePendingImports()
            resumeFinished.withValue { $0 = true }
        }
        for _ in 0 ..< 10_000 where !resumeFinished.snapshot {
            await Task.yield()
        }
        XCTAssertTrue(
            resumeFinished.snapshot,
            "resumePendingImports blocked on the foreground import instead of skipping it"
        )

        // The user is still watching import A; B progressed durably only.
        XCTAssertEqual(coordinator.operation, .importJob(jobA.id))
        XCTAssertEqual(coordinator.state, .importing(jobID: jobA.id))
        XCTAssertEqual(
            repository.importJobs.first { $0.id == jobB.id }?.status,
            .ready
        )

        await service.release(jobA.id.uuidString)
        await submitTask.value
        await resumeTask.value

        XCTAssertEqual(coordinator.state, .completed(recipeID: recipeA.id))
        XCTAssertEqual(coordinator.completedRecipe?.id, recipeA.id)
        XCTAssertEqual(
            Set(repository.recipes.map(\.id)),
            [recipeA.id, recipeB.id]
        )
    }

    func testResumeDoesNotSwapWhichRecipeTheSheetReportsCompleted() async throws {
        // Same overlap, asserted on the terminal state: the sheet's success
        // screen must name the recipe the user imported, not the one the
        // share extension queued. (#32)
        let service = GatedImportService()
        let repository = ImportTestRepository()
        let coordinator = ImportCoordinator(
            repository: repository,
            service: service,
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )
        let submitTask = Task {
            await coordinator.submit(
                urlText: "https://youtu.be/foreground-import"
            )
        }
        while repository.importJobs.first?.remoteJobID == nil {
            await Task.yield()
        }
        let jobA = try XCTUnwrap(repository.importJobs.first)
        let recipeA = importRecipe(
            title: "Foreground Recipe",
            originalURL: jobA.sourceURL
        )
        await service.setRecipe(recipeA, forJob: jobA.id.uuidString)
        await service.release(jobA.id.uuidString)

        var jobB = ImportJob.queued(
            sourceURL: URL(string: "https://youtu.be/background-share")!,
            source: .youtube
        )
        jobB.remoteJobID = jobB.id.uuidString.lowercased()
        try repository.save(jobB)
        let recipeB = importRecipe(
            title: "Background Recipe",
            originalURL: jobB.sourceURL
        )
        await service.setRecipe(recipeB, forJob: jobB.id.uuidString)
        await service.release(jobB.id.uuidString)

        await coordinator.resumePendingImports()
        await submitTask.value

        XCTAssertEqual(coordinator.operation, .importJob(jobA.id))
        XCTAssertEqual(coordinator.completedRecipe?.id, recipeA.id)
        XCTAssertEqual(coordinator.state, .completed(recipeID: recipeA.id))
        XCTAssertEqual(
            repository.importJobs.first { $0.id == jobB.id }?.status,
            .ready
        )
        XCTAssertEqual(
            Set(repository.recipes.map(\.id)),
            [recipeA.id, recipeB.id]
        )
    }

    func testServerReportedCancellationRemovesJobAndReadsAsCancelled() async throws {
        // The server reports a job the user had already cancelled
        // (idempotent resubmission, another session's cancel). That must
        // read as cancelled — not as a failure, and the durable row must
        // not linger as a phantom .parsing import.
        let service = CancelledRemotelyImportService()
        let repository = ImportTestRepository()
        let coordinator = ImportCoordinator(
            repository: repository,
            service: service,
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.submit(
            urlText: "https://youtu.be/cancelled-elsewhere"
        )

        XCTAssertTrue(
            repository.importJobs.isEmpty,
            "A remotely cancelled job must leave the Inbox"
        )
        let jobID = try XCTUnwrap(coordinator.operation?.jobID)
        XCTAssertEqual(coordinator.state, .cancelled(jobID: jobID))
        XCTAssertNil(coordinator.operationFailure)
    }

    func testDismissedCancelledReimportReleasesTheOperationForNewImports() async throws {
        // A reimport's poll learns the job was cancelled elsewhere:
        // finishRemoteCancellation deletes the durable row and presents
        // .cancelled, deliberately keeping `operation` so the sheet can
        // show the outcome. A swipe-down dismissal of that sheet runs no
        // view code of its own, so the release must come from the
        // presentation's dismissal hook — otherwise AddRecipeSheet stays
        // wedged behind "Re-import in progress" with no durable row left
        // to finish it from the Inbox.
        let current = importRecipe(
            title: "Current Curry",
            originalURL: URL(string: "https://youtu.be/current-curry")!
        )
        let newRecipe = importRecipe(
            title: "After The Wedge",
            originalURL: URL(string: "https://youtu.be/after-the-wedge")!
        )
        let repository = ImportTestRepository(recipes: [current])
        let coordinator = ImportCoordinator(
            repository: repository,
            service: CancelledReimportThenReadyImportService(
                readyRecipe: newRecipe
            ),
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.reimport(recipe: current)

        let cancelledJobID = try XCTUnwrap(coordinator.operation?.jobID)
        XCTAssertEqual(
            coordinator.state,
            .cancelled(jobID: cancelledJobID)
        )
        XCTAssertEqual(coordinator.operation?.isReimport, true)

        // The user swipes the sheet away; the dismissal cleanup is all
        // that runs.
        coordinator.releaseReimport(for: current.id)

        XCTAssertNil(
            coordinator.operation,
            "A dismissed cancelled reimport must release the coordinator"
        )
        XCTAssertEqual(coordinator.state, .idle)

        await coordinator.submit(
            urlText: "https://youtu.be/after-the-wedge"
        )

        XCTAssertEqual(
            coordinator.state,
            .completed(recipeID: newRecipe.id),
            "Add Recipe must be usable again after the sheet is gone"
        )
        XCTAssertTrue(repository.recipes.contains(newRecipe))
    }

    func testDismissedFailedReimportKeepsTheInboxRowAndFreesAddRecipe() async throws {
        let current = importRecipe(
            title: "Current Curry",
            originalURL: URL(string: "https://youtu.be/current-curry")!
        )
        let repository = ImportTestRepository(recipes: [current])
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

        await coordinator.reimport(recipe: current)

        let jobID = try XCTUnwrap(coordinator.operation?.jobID)
        XCTAssertEqual(
            coordinator.state,
            .failed(jobID: jobID, reason: .parserUnavailable)
        )

        coordinator.releaseReimport(for: current.id)

        XCTAssertNil(coordinator.operation)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(
            repository.importJobs.first?.status,
            .failed(.parserUnavailable),
            "The durable row must stay for the Inbox's recovery actions"
        )
    }

    func testReleaseReimportLeavesALiveReimportAlone() async throws {
        // Both dismissal affordances are disabled while an owned
        // reimport is importing; if the presentation is torn down some
        // other way, the release must not abandon the live operation —
        // reopening the sheet re-attaches to it.
        let current = importRecipe(
            title: "Current Curry",
            originalURL: URL(string: "https://youtu.be/current-curry")!
        )
        let service = TransportOnCancelSubmitImportService()
        let repository = ImportTestRepository(recipes: [current])
        let coordinator = ImportCoordinator(
            repository: repository,
            service: service,
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )
        let task = Task {
            await coordinator.reimport(recipe: current)
        }
        var submitStarted = false
        while !submitStarted {
            submitStarted = await service.submitStarted
            await Task.yield()
        }
        let jobID = try XCTUnwrap(repository.importJobs.first?.id)
        XCTAssertEqual(coordinator.state, .importing(jobID: jobID))

        coordinator.releaseReimport(for: current.id)

        XCTAssertEqual(
            coordinator.state,
            .importing(jobID: jobID),
            "A live reimport keeps its published state"
        )
        XCTAssertEqual(
            coordinator.operation,
            .reimport(jobID: jobID, currentRecipeID: current.id)
        )

        await coordinator.cancelImport(jobID: jobID)
        await task.value
    }

    func testReleaseReimportForAnotherRecipeLeavesTheOperationAlone() async throws {
        // The sheet for a different recipe shows "Another import is
        // active"; dismissing it must not clobber the pending decision
        // it was not presenting.
        let current = importRecipe(
            title: "Current Curry",
            originalURL: URL(string: "https://youtu.be/current-curry")!
        )
        let other = importRecipe(
            title: "Unrelated Udon",
            originalURL: URL(string: "https://youtu.be/unrelated-udon")!
        )
        let repository = ImportTestRepository(recipes: [current, other])
        let coordinator = ImportCoordinator(
            repository: repository,
            service: ContextualNeedsReviewImportService(),
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.reimport(recipe: current)

        let operation = try XCTUnwrap(coordinator.operation)
        let state = coordinator.state

        coordinator.releaseReimport(for: other.id)

        XCTAssertEqual(coordinator.operation, operation)
        XCTAssertEqual(coordinator.state, state)
    }

    func testReleaseDuringAPendingDecisionIsRecoverableFromTheDurableRow() async throws {
        // Dismissal is disabled while a decision is pending, so the
        // release only fires there on presentation teardown — and it
        // must strand nothing: the durable row re-presents the decision
        // the next time the sheet opens for that recipe.
        let current = importRecipe(
            title: "Current Curry",
            originalURL: URL(string: "https://youtu.be/current-curry")!
        )
        let repository = ImportTestRepository(recipes: [current])
        let coordinator = ImportCoordinator(
            repository: repository,
            service: ContextualNeedsReviewImportService(),
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.reimport(recipe: current)

        let candidateID = try XCTUnwrap(
            repository.importJobs.first?.candidateRecipeID
        )
        XCTAssertEqual(
            coordinator.state,
            .needsReview(recipeID: candidateID)
        )

        coordinator.releaseReimport(for: current.id)

        XCTAssertNil(coordinator.operation)

        coordinator.resumePendingReimport(for: current.id)

        XCTAssertTrue(
            coordinator.state.isReplacementDecision,
            "The released decision must come back, not strand the row"
        )
        XCTAssertEqual(coordinator.completedRecipe?.id, candidateID)
    }

    func testReimportSheetDismissalIsWiredToReleaseTheOperation() throws {
        // The composed tests above pin the release semantics; this pins
        // the wiring: the sheet's onDismiss covers the swipe-down that
        // runs no other cleanup, and the Close button routes through the
        // same release so the two dismissals cannot drift apart again.
        XCTAssertTrue(
            try source("Ladle/RecipeDetail/RecipeDetailView.swift")
                .contains("importCoordinator.releaseReimport(")
        )
        XCTAssertTrue(
            try source("Ladle/Edit/ReimportSheet.swift")
                .contains(
                    "coordinator.releaseReimport(for: currentRecipe.id)"
                )
        )
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testCancelBeforeRemoteJobAssignedStaysCancelledAndSkipsRemoteCancel() async throws {
        // The cancel lands while the initial submit POST is still in
        // flight, before any remote job ID exists. (#30, #31)
        let service = TransportOnCancelSubmitImportService()
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
                urlText: "https://youtu.be/cancel-mid-submit"
            )
        }
        var submitStarted = false
        while !submitStarted {
            submitStarted = await service.submitStarted
            await Task.yield()
        }
        let jobID = try XCTUnwrap(repository.importJobs.first?.id)
        XCTAssertNil(repository.importJobs.first?.remoteJobID)

        await coordinator.cancelImport(jobID: jobID)
        await task.value

        XCTAssertTrue(
            repository.importJobs.isEmpty,
            "The cancelled job was saved back: \(repository.importJobs)"
        )
        XCTAssertEqual(coordinator.state, .idle)
        let cancelCount = await service.cancelCount
        XCTAssertEqual(
            cancelCount,
            0,
            "There is no remote job to cancel yet"
        )
    }

    func testSecondCancelOfTheSameJobIsANoOp() async throws {
        let service = CancellablePollingImportService()
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
                urlText: "https://youtu.be/cancel-twice"
            )
        }
        while repository.importJobs.first?.remoteJobID == nil {
            await Task.yield()
        }
        let jobID = try XCTUnwrap(repository.importJobs.first?.id)

        await coordinator.cancelImport(jobID: jobID)
        await coordinator.cancelImport(jobID: jobID)
        await task.value

        XCTAssertTrue(repository.importJobs.isEmpty)
        XCTAssertEqual(coordinator.state, .idle)
        let cancelCount = await service.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testCancellingACompletedImportRemovesTheJobKeepsTheRecipeAndSkipsRemoteCancel() async throws {
        // The import finished in the race window before the user's cancel
        // landed. The Inbox row goes away as promised; the saved recipe and
        // the terminal remote job are left alone.
        let service = ReadyThenCountingCancelImportService()
        let repository = ImportTestRepository()
        let coordinator = ImportCoordinator(
            repository: repository,
            service: service,
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.submit(
            urlText: "https://youtu.be/finished-before-cancel"
        )
        let jobID = try XCTUnwrap(repository.importJobs.first?.id)
        XCTAssertEqual(repository.importJobs.first?.status, .ready)

        await coordinator.cancelImport(jobID: jobID)

        XCTAssertTrue(repository.importJobs.isEmpty)
        XCTAssertEqual(repository.recipes.count, 1)
        XCTAssertEqual(coordinator.state, .idle)
        let cancelCount = await service.cancelCount
        XCTAssertEqual(
            cancelCount,
            0,
            "A terminal remote job must not receive a cancel request"
        )
    }

    func testCancellingWhileOfflineStillCancelsLocally() async throws {
        // The remote cancel cannot reach the server. The local job still
        // disappears as promised instead of surfacing a persistence
        // failure for a cancel that locally succeeded.
        let service = OfflineCancelImportService()
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
                urlText: "https://youtu.be/cancel-offline"
            )
        }
        while repository.importJobs.first?.remoteJobID == nil {
            await Task.yield()
        }
        let jobID = try XCTUnwrap(repository.importJobs.first?.id)

        await coordinator.cancelImport(jobID: jobID)
        await task.value

        XCTAssertTrue(repository.importJobs.isEmpty)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testSignOutQuiesceDropsARacingStatusResponseWithoutWriting() async throws {
        // Sign-out quiesces the coordinator while the final status
        // response is already in flight; the poll resumes with a
        // successful update after cancellation. Nothing may be written,
        // and the remote job is not cancelled — it still belongs to the
        // signed-out account's server library. (final sweep S1)
        let service = RacingStatusImportService()
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
                urlText: "https://youtu.be/sign-out-races-response"
            )
        }
        var polling = false
        while !polling {
            polling = await service.statusStarted
            await Task.yield()
        }

        await coordinator.quiesceForSignOut()
        await task.value

        XCTAssertTrue(
            repository.recipes.isEmpty,
            "The raced response was written after sign-out: \(repository.recipes.map(\.title))"
        )
        XCTAssertEqual(repository.importJobs.first?.status, .parsing)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.operation)
        let cancelCount = await service.cancelCount
        XCTAssertEqual(
            cancelCount,
            0,
            "Sign-out must not cancel the account's remote job"
        )
    }

    func testSignOutQuiesceDoesNotResurrectAWipedJobAsAuthExpired() async throws {
        // The deterministic sweep trace: sign-out clears the token store,
        // so the woken poll's status call throws missingAuthentication.
        // Quiesced, that must unwind as a cancellation — not transition
        // the row to failed(.authenticationExpired) and re-insert it into
        // the store the wipe empties next. (final sweep S1)
        let service = AuthExpiredOnCancelPollingImportService()
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
                urlText: "https://youtu.be/sign-out-auth-expiry"
            )
        }
        var polling = false
        while !polling {
            polling = await service.statusStarted
            await Task.yield()
        }

        await coordinator.quiesceForSignOut()
        XCTAssertEqual(
            repository.importJobs.first?.status,
            .parsing,
            "The quiesced import repersisted itself as a durable failure"
        )

        // The runtime wipes after quiescing; nothing may come back.
        repository.importJobs.removeAll()
        await task.value
        XCTAssertTrue(
            repository.importJobs.isEmpty,
            "The wiped job was re-inserted: \(repository.importJobs)"
        )
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testSignOutQuiesceCancelsEveryConcurrentImport() async throws {
        // A foreground import polls in the sheet while resume drives a
        // second shared-queue job. Sign-out must drain both writers, not
        // just the one the coordinator's operation points at.
        // (final sweep S1)
        let service = GatedImportService()
        let repository = ImportTestRepository()
        let coordinator = ImportCoordinator(
            repository: repository,
            service: service,
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )
        let submitTask = Task {
            await coordinator.submit(
                urlText: "https://youtu.be/foreground-import"
            )
        }
        while repository.importJobs.first?.remoteJobID == nil {
            await Task.yield()
        }
        let jobA = try XCTUnwrap(repository.importJobs.first)

        var jobB = ImportJob.queued(
            sourceURL: URL(string: "https://youtu.be/background-share")!,
            source: .youtube
        )
        jobB.remoteJobID = jobB.id.uuidString.lowercased()
        try repository.save(jobB)
        let resumeTask = Task {
            await coordinator.resumePendingImports()
        }
        var pollingBoth = false
        while !pollingBoth {
            let polling = await service.polling
            pollingBoth = polling.count == 2
            await Task.yield()
        }

        await coordinator.quiesceForSignOut()
        await submitTask.value
        await resumeTask.value

        XCTAssertTrue(repository.recipes.isEmpty)
        XCTAssertEqual(
            repository.importJobs.map(\.status),
            [.parsing, .parsing]
        )
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.operation)
        XCTAssertEqual(
            Set(repository.importJobs.map(\.id)),
            [jobA.id, jobB.id]
        )
    }

    func testSignOutQuiesceWithNothingInFlightClearsStaleOperationState() async throws {
        // Sign-out with no import running: quiesce returns immediately,
        // and the completed operation's published state is cleared so the
        // next account's first import or reimport is not blocked by it.
        // (final sweep S1)
        let repository = ImportTestRepository()
        let coordinator = makeCoordinator(repository: repository)

        await coordinator.submit(
            urlText: "https://youtu.be/ready-green-curry"
        )
        guard case .completed = coordinator.state else {
            return XCTFail("Expected a completed import to quiesce after")
        }
        XCTAssertNotNil(coordinator.operation)

        await coordinator.quiesceForSignOut()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.operation)
        XCTAssertNil(coordinator.completedRecipe)
        // Quiescing never touches durable rows — the wipe that follows
        // owns those.
        XCTAssertEqual(repository.recipes.count, 1)
        XCTAssertEqual(repository.importJobs.count, 1)
    }

    func testAuthenticationExpiryMakesAdmissionJobDurablyFailed() async {
        let repository = ImportTestRepository()
        let coordinator = ImportCoordinator(
            repository: repository,
            service: ThrowingImportService(error: .authenticationExpired),
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.submit(
            urlText: "https://youtu.be/expired-session"
        )

        XCTAssertEqual(
            repository.importJobs.first?.status,
            .failed(.authenticationExpired)
        )
        guard case .failed = coordinator.state else {
            return XCTFail("Expected a visible terminal failure")
        }
        XCTAssertEqual(
            coordinator.operationFailure?.report?.failure,
            .authenticationExpired
        )
        XCTAssertEqual(
            coordinator.operationFailure?.retryAvailability(at: .now),
            .afterSignIn
        )
    }

    func testTransportFailureMakesAdmissionJobDurablyFailed() async {
        let repository = ImportTestRepository()
        let coordinator = ImportCoordinator(
            repository: repository,
            service: ThrowingImportService(error: .transport),
            accountSession: AccountSession(
                store: ImportTestPreferenceStore()
            ),
            clock: ImmediateImportClock()
        )

        await coordinator.submit(
            urlText: "https://youtu.be/interrupted-import"
        )

        XCTAssertEqual(
            repository.importJobs.first?.status,
            .failed(.networkUnavailable)
        )
        XCTAssertEqual(
            coordinator.operationFailure?.report?.failure,
            .offline
        )
        XCTAssertEqual(
            coordinator.operationFailure?.retryAvailability(at: .now),
            .available
        )
    }

    func testCapacityErrorsKeepPreciseOperationStateAndSavedLink() async throws {
        let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(String, [String: String]?, RemoteFailure, ImportFailure)] = [
            (
                "providerUnavailable",
                nil,
                .serviceUnavailable,
                .parserUnavailable
            ),
            ("quotaExceeded", nil, .quotaExceeded, .quotaExceeded),
            (
                "rateLimited",
                ["retryAt": "2027-01-15T08:00:00.000Z"],
                .rateLimited(retryAt: retryAt),
                .quotaExceeded
            ),
        ]

        for (index, value) in cases.enumerated() {
            let repository = ImportTestRepository()
            let coordinator = ImportCoordinator(
                repository: repository,
                service: ThrowingImportService(
                    error: try remoteAPIError(
                        code: value.0,
                        details: value.1
                    )
                ),
                accountSession: AccountSession(
                    store: ImportTestPreferenceStore()
                ),
                clock: ImmediateImportClock()
            )
            let url = URL(
                string: "https://youtu.be/capacity-\(index)"
            )!

            await coordinator.submit(urlText: url.absoluteString)

            let job = try XCTUnwrap(repository.importJobs.first)
            XCTAssertEqual(job.sourceURL, url)
            XCTAssertEqual(job.status, .failed(value.3))
            XCTAssertEqual(
                coordinator.operationFailure?.report?.failure,
                value.2
            )
            XCTAssertEqual(coordinator.operationFailure?.jobID, job.id)
        }
    }

    func testRetryEligibilityExplainsCapacityAuthAndManualRecovery() throws {
        let jobID = UUID()
        let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
        let limitedError = try remoteAPIError(
            code: "rateLimited",
            details: ["retryAt": "2027-01-15T08:00:00.000Z"]
        )
        let limited = ImportOperationFailure(
            jobID: jobID,
            reason: .quotaExceeded,
            report: RemoteFailureReport(limitedError)
        )

        XCTAssertEqual(
            limited.retryAvailability(
                at: retryAt.addingTimeInterval(-1)
            ),
            .after(retryAt)
        )
        XCTAssertEqual(
            limited.retryAvailability(at: retryAt),
            .available
        )
        XCTAssertNotEqual(
            ImportRetryAvailability.after(retryAt).buttonTitle(
                at: retryAt.addingTimeInterval(-1)
            ),
            "Retry import"
        )
        XCTAssertEqual(
            ImportRetryAvailability.after(retryAt).buttonTitle(at: retryAt),
            "Retry import"
        )

        let quota = ImportOperationFailure(
            jobID: jobID,
            reason: .quotaExceeded
        )
        XCTAssertEqual(
            quota.retryAvailability(at: retryAt),
            .afterCapacityResets
        )
        XCTAssertTrue(quota.message.contains("capacity"))

        let auth = ImportOperationFailure(
            jobID: jobID,
            reason: .authenticationExpired
        )
        XCTAssertEqual(
            auth.retryAvailability(at: retryAt),
            .afterSignIn
        )
        XCTAssertTrue(auth.message.contains("Sign in"))

        for reason in [ImportFailure.invalidURL, .unsupportedSource] {
            let failure = ImportOperationFailure(
                jobID: jobID,
                reason: reason
            )
            XCTAssertEqual(
                failure.retryAvailability(at: retryAt),
                .manualRecovery
            )
            XCTAssertTrue(failure.message.contains("manually"))
        }
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

@MainActor
private final class FailingGoogleSignInProvider: GoogleSignInProviding {
    func signIn() async throws -> String {
        throw GoogleSignInProviderError.missingIdentityToken
    }

    func signOut() {}

    func disconnect() async {}

    func handle(_ url: URL) -> Bool {
        false
    }
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

private actor CancellablePollingImportService: ImportService {
    private(set) var cancelCount = 0

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
        while !Task.isCancelled {
            await Task.yield()
        }
        throw CancellationError()
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

    func cancel(remoteJobID: String) async throws {
        cancelCount += 1
    }
}

/// The status response was already in flight when the cancel landed, so the
/// awaiting poll resumes with a successful terminal update.
private actor RacingStatusImportService: ImportService {
    private(set) var cancelCount = 0
    private(set) var statusStarted = false

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
        statusStarted = true
        while !Task.isCancelled {
            await Task.yield()
        }
        return ImportServiceUpdate(
            remoteJobID: remoteJobID,
            progress: .ready(importRecipe(
                title: "Raced Recipe",
                originalURL: URL(string: "https://youtu.be/raced")!
            ))
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

    func cancel(remoteJobID: String) async throws {
        cancelCount += 1
    }
}

/// Cancellation makes the in-flight poll fail with a typed network error —
/// what a cancelled URLSession call surfaced before #33, and what a
/// genuinely failing request still throws in the same race window.
private actor TransportOnCancelPollingImportService: ImportService {
    private(set) var cancelCount = 0
    private(set) var statusStarted = false

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
        statusStarted = true
        while !Task.isCancelled {
            await Task.yield()
        }
        throw APIError.transport
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

    func cancel(remoteJobID: String) async throws {
        cancelCount += 1
    }
}

/// Sign-out has already cleared the token store, so a poll that wakes
/// while being quiesced fails with the missing-authentication error the
/// real APIClient throws.
private actor AuthExpiredOnCancelPollingImportService: ImportService {
    private(set) var statusStarted = false

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
        statusStarted = true
        while !Task.isCancelled {
            await Task.yield()
        }
        throw APIError.missingAuthentication
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

/// Holds every job in `.parsing` until the test releases it, then resolves
/// it `.ready` with the recipe registered for that job.
private actor GatedImportService: ImportService {
    private var released: Set<String> = []
    private var recipes: [String: Recipe] = [:]
    private(set) var polling: Set<String> = []

    func setRecipe(_ recipe: Recipe, forJob remoteJobID: String) {
        recipes[remoteJobID.lowercased()] = recipe
    }

    func release(_ remoteJobID: String) {
        released.insert(remoteJobID.lowercased())
    }

    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(
            remoteJobID: job.id.uuidString.lowercased(),
            progress: .parsing
        )
    }

    func status(remoteJobID: String) async throws -> ImportServiceUpdate {
        let key = remoteJobID.lowercased()
        polling.insert(key)
        while !released.contains(key) {
            try Task.checkCancellation()
            await Task.yield()
        }
        guard let recipe = recipes[key] else {
            throw APIError.invalidResponse
        }
        return ImportServiceUpdate(
            remoteJobID: key,
            progress: .ready(recipe)
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

/// The server reports the polled job as cancelled.
private actor CancelledRemotelyImportService: ImportService {
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
        throw RemoteContractError.importCancelled
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

/// The reimport's poll learns the job was cancelled elsewhere; a fresh
/// import submitted afterwards completes immediately.
private actor CancelledReimportThenReadyImportService: ImportService {
    let readyRecipe: Recipe

    init(readyRecipe: Recipe) {
        self.readyRecipe = readyRecipe
    }

    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        if job.currentRecipeID != nil {
            return ImportServiceUpdate(
                remoteJobID: job.id.uuidString,
                progress: .parsing
            )
        }
        return ImportServiceUpdate(
            remoteJobID: job.id.uuidString,
            progress: .ready(readyRecipe)
        )
    }

    func status(remoteJobID: String) async throws -> ImportServiceUpdate {
        throw RemoteContractError.importCancelled
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

/// The initial submit POST hangs until cancelled, then fails with a typed
/// network error; no remote job ID is ever assigned.
private actor TransportOnCancelSubmitImportService: ImportService {
    private(set) var cancelCount = 0
    private(set) var submitStarted = false

    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        submitStarted = true
        while !Task.isCancelled {
            await Task.yield()
        }
        throw APIError.transport
    }

    func status(remoteJobID: String) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(
            remoteJobID: remoteJobID,
            progress: .parsing
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

    func cancel(remoteJobID: String) async throws {
        cancelCount += 1
    }
}

/// Completes the import immediately and counts remote cancel requests.
private actor ReadyThenCountingCancelImportService: ImportService {
    private(set) var cancelCount = 0

    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(
            remoteJobID: job.id.uuidString,
            progress: .ready(importRecipe(
                title: "Finished Recipe",
                originalURL: job.sourceURL
            ))
        )
    }

    func status(remoteJobID: String) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(
            remoteJobID: remoteJobID,
            progress: .parsing
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

    func cancel(remoteJobID: String) async throws {
        cancelCount += 1
    }
}

/// The poll ends in ordinary cancellation, but the remote cancel request
/// itself fails — the device is offline.
private actor OfflineCancelImportService: ImportService {
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
        while !Task.isCancelled {
            await Task.yield()
        }
        throw CancellationError()
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

    func cancel(remoteJobID: String) async throws {
        throw APIError.transport
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

private actor ContextualNeedsReviewImportService: ImportService {
    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        let recipe = importRecipe(
            id: job.candidateRecipeID ?? job.id,
            title: "Recipe to Review",
            originalURL: job.sourceURL
        )
        return ImportServiceUpdate(
            remoteJobID: job.id.uuidString,
            progress: .needsReview(recipe)
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
