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
    func insufficientTextEvidenceHasAStableWireValue() {
        #expect(
            ImportFailure.insufficientTextEvidence.rawValue
                == "insufficientTextEvidence"
        )
    }

    @Test
    func aFailureCodeThisBuildDoesNotKnowDecodesInsteadOfThrowing() throws {
        let decoded = try JSONDecoder().decode(
            ImportFailure.self,
            from: Data("\"someCodeFromALaterServer\"".utf8)
        )

        #expect(decoded == .unrecognized("someCodeFromALaterServer"))
    }

    @Test
    func anUnrecognisedCodeSurvivesTheDurableJobPayload() throws {
        // The job is stored as encoded JSON, so dropping the string here
        // would lose it for good: a build that later learns the code would
        // still read the row as a generic failure.
        let failed = try ImportJob.queued(sourceURL: sourceURL)
            .transitioning(to: .failed(.unrecognized("someCodeFromALaterServer")))

        let restored = try JSONDecoder().decode(
            ImportJob.self,
            from: JSONEncoder().encode(failed)
        )

        #expect(
            restored.status
                == .failed(.unrecognized("someCodeFromALaterServer"))
        )
    }

    @Test
    func aKnownFailureKeepsTheWireShapeAlreadyOnDisk() throws {
        // Import jobs persisted by earlier builds hold this exact JSON in
        // their SwiftData payload. A failure reason that stopped encoding as
        // a bare string would make every stored failed job undecodable.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(ImportStatus.failed(.parserUnavailable))

        #expect(
            String(decoding: encoded, as: UTF8.self)
                == #"{"failed":{"_0":"parserUnavailable"}}"#
        )
    }

    @Test
    func everyKnownFailureRoundTripsThroughItsWireValue() throws {
        let known: [ImportFailure] = [
            .parserUnavailable,
            .insufficientTextEvidence,
            .privateOrDeleted,
            .unsupportedSource,
            .invalidURL,
            .networkUnavailable,
            .authenticationExpired,
            .quotaExceeded,
        ]

        for failure in known {
            #expect(ImportFailure(rawValue: failure.rawValue) == failure)
        }
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

    @Test
    func remoteReimportAdoptsServerAssignedCandidate() throws {
        let currentRecipeID = UUID()
        let localPlaceholderID = UUID()
        let candidate = Recipe(
            title: "Server candidate",
            source: .tiktok,
            originalURL: sourceURL,
            servings: 2
        )
        let job = ImportJob.reimporting(
            sourceURL: sourceURL,
            currentRecipeID: currentRecipeID,
            candidateRecipeID: localPlaceholderID
        )

        let updated = try job.awaitingRemoteReview(candidate: candidate)

        #expect(updated.status == .needsReview)
        #expect(updated.currentRecipeID == currentRecipeID)
        #expect(updated.candidateRecipeID == candidate.id)
        #expect(updated.reviewCandidate == candidate)
    }
}
