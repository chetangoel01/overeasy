import Foundation
import Testing
@testable import LadleCore

@Suite("Import job transitions")
struct ImportJobTests {
    private let sourceURL = URL(string: "https://www.tiktok.com/@cook/video/123")!

    @Test
    func parsingCanBecomeReady() throws {
        let job = ImportJob.queued(sourceURL: sourceURL)

        let updated = try job.transitioning(to: .ready)

        #expect(updated.status == .ready)
    }

    @Test
    func parsingCanBecomeNeedsReview() throws {
        let job = ImportJob.queued(sourceURL: sourceURL)

        let updated = try job.transitioning(to: .needsReview)

        #expect(updated.status == .needsReview)
    }

    @Test
    func needsReviewRecordsRecipeItCanResume() throws {
        let recipeID = UUID()

        let updated = try ImportJob.queued(sourceURL: sourceURL)
            .awaitingReview(recipeID: recipeID)

        #expect(updated.status == .needsReview)
        #expect(updated.reviewRecipeID == recipeID)
    }

    @Test
    func parsingCanFail() throws {
        let job = ImportJob.queued(sourceURL: sourceURL)

        let updated = try job.transitioning(to: .failed(.parserUnavailable))

        #expect(updated.status == .failed(.parserUnavailable))
    }

    @Test
    func readyCannotReturnToParsing() throws {
        let ready = try ImportJob.queued(sourceURL: sourceURL)
            .transitioning(to: .ready)

        #expect(throws: ImportTransitionError.self) {
            try ready.transitioning(to: .parsing)
        }
    }

    @Test
    func failedReimportRetainsCurrentRecipe() throws {
        let usableRecipeID = UUID()
        let candidateRecipeID = UUID()
        let job = ImportJob.reimporting(
            sourceURL: sourceURL,
            currentRecipeID: usableRecipeID,
            candidateRecipeID: candidateRecipeID
        )

        let updated = try job.transitioning(to: .failed(.parserUnavailable))

        #expect(updated.currentRecipeID == usableRecipeID)
        #expect(updated.candidateRecipeID == nil)
    }

    @Test
    func keepingCurrentRecipeClearsReviewedCandidate() throws {
        let currentRecipeID = UUID()
        let candidateRecipeID = UUID()
        let job = try ImportJob.reimporting(
            sourceURL: sourceURL,
            currentRecipeID: currentRecipeID,
            candidateRecipeID: candidateRecipeID
        )
        .awaitingReview(recipeID: candidateRecipeID)

        let updated = try job.keepingCurrentRecipe()

        #expect(updated.status == .ready)
        #expect(updated.currentRecipeID == currentRecipeID)
        #expect(updated.candidateRecipeID == nil)
    }

    @Test
    func reimportReviewPersistsCandidateWithoutExposingItAsCurrent() throws {
        let currentRecipeID = UUID()
        let candidate = Recipe(
            title: "Candidate",
            source: .tiktok,
            originalURL: sourceURL,
            servings: 2
        )
        let job = try ImportJob.reimporting(
            sourceURL: sourceURL,
            currentRecipeID: currentRecipeID,
            candidateRecipeID: candidate.id
        )
        .awaitingReview(candidate: candidate)

        #expect(job.status == .needsReview)
        #expect(job.currentRecipeID == currentRecipeID)
        #expect(job.reviewRecipeID == currentRecipeID)
        #expect(job.reviewCandidate == candidate)
    }
}
