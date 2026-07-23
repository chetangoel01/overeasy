import Foundation
import LadleCore
import Observation

enum ImportValidationError: Error, Equatable {
    case invalidURL
    case unsupportedSource
}

enum ImportCoordinatorState: Equatable {
    case idle
    case validationFailed(ImportValidationError)
    case duplicate(existingRecipeID: UUID)
    case guestLimit(GuestSaveDecision)
    case importing(jobID: UUID)
    case completed(recipeID: UUID)
    case needsReview(recipeID: UUID)
    case failed(jobID: UUID, reason: ImportFailure)
    case persistenceFailed
}

protocol ImportClock: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousImportClock: ImportClock {
    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

@MainActor
@Observable
final class ImportCoordinator {
    private struct Submission {
        let url: URL
        let source: RecipeSource
    }

    private struct ManualSubmission {
        let title: String
        let details: String
    }

    @ObservationIgnored
    private let repository: RecipeRepository

    @ObservationIgnored
    private let service: any ImportService

    @ObservationIgnored
    private let accountSession: AccountSession

    @ObservationIgnored
    private let clock: any ImportClock

    private let parsingDelay: Duration
    private var pendingSubmission: Submission?
    private var pendingManualSubmission: ManualSubmission?

    private(set) var state: ImportCoordinatorState = .idle
    private(set) var existingDuplicate: Recipe?
    private(set) var completedRecipe: Recipe?

    init(
        repository: RecipeRepository,
        service: any ImportService,
        accountSession: AccountSession,
        clock: any ImportClock = ContinuousImportClock(),
        parsingDelay: Duration = .milliseconds(450)
    ) {
        self.repository = repository
        self.service = service
        self.accountSession = accountSession
        self.clock = clock
        self.parsingDelay = parsingDelay
    }

    var isImporting: Bool {
        if case .importing = state {
            true
        } else {
            false
        }
    }

    func submit(
        urlText: String,
        allowingDuplicate: Bool = false,
        bypassingGuestPrompt: Bool = false
    ) async {
        existingDuplicate = nil
        completedRecipe = nil
        pendingManualSubmission = nil

        let submission: Submission
        do {
            submission = try makeSubmission(urlText: urlText)
        } catch let validationError as ImportValidationError {
            state = .validationFailed(validationError)
            return
        } catch {
            state = .validationFailed(.invalidURL)
            return
        }
        pendingSubmission = submission

        do {
            let recipes = try repository.fetchRecipes()
            if !allowingDuplicate,
               let duplicate = recipes.first(
                   where: {
                       canonicalURL($0.originalURL)
                           == canonicalURL(submission.url)
                   }
               ) {
                existingDuplicate = duplicate
                state = .duplicate(existingRecipeID: duplicate.id)
                return
            }

            let decision = accountSession.saveDecision(
                savedRecipeCount: recipes.count
            )
            switch decision {
            case .allow:
                break
            case .allowWithAccountPrompt where bypassingGuestPrompt:
                break
            case .allowWithAccountPrompt, .limitReached:
                state = .guestLimit(decision)
                return
            }

            let job = ImportJob.queued(
                sourceURL: submission.url,
                source: submission.source
            )
            try repository.save(job)
            await process(job)
        } catch {
            state = .persistenceFailed
        }
    }

    func importDuplicateCopy() async {
        guard let pendingSubmission else {
            state = .persistenceFailed
            return
        }
        await submit(
            urlText: pendingSubmission.url.absoluteString,
            allowingDuplicate: true
        )
    }

    func continueAfterGuestPrompt() async {
        if let pendingSubmission {
            await submit(
                urlText: pendingSubmission.url.absoluteString,
                bypassingGuestPrompt: true
            )
        } else if let pendingManualSubmission {
            await createManualRecipe(
                title: pendingManualSubmission.title,
                details: pendingManualSubmission.details,
                bypassingGuestPrompt: true
            )
        } else {
            state = .persistenceFailed
        }
    }

    func retry(
        jobID: UUID,
        correctionNotes: String? = nil,
        pastedRecipeText: String? = nil
    ) async {
        completedRecipe = nil

        do {
            guard var job = try repository.fetchImportJobs().first(
                where: { $0.id == jobID }
            ) else {
                state = .persistenceFailed
                return
            }

            if let correctionNotes = normalized(correctionNotes) {
                job.correctionNotes = correctionNotes
            }
            if let pastedRecipeText = normalized(pastedRecipeText) {
                job.pastedRecipeText = pastedRecipeText
            }

            guard case .failed = job.status else {
                state = .persistenceFailed
                return
            }

            let isReimport = job.currentRecipeID != nil
            if isReimport {
                job = try job.retryingReimport(
                    candidateRecipeID: UUID()
                )
            } else {
                job = try job.transitioning(to: .parsing)
            }
            try repository.save(job)
            if isReimport {
                await processReimport(job)
            } else {
                await process(job)
            }
        } catch {
            state = .persistenceFailed
        }
    }

    func createManualRecipe(
        title: String,
        details: String
    ) async {
        await createManualRecipe(
            title: title,
            details: details,
            bypassingGuestPrompt: false
        )
    }

    private func createManualRecipe(
        title: String,
        details: String,
        bypassingGuestPrompt: Bool
    ) async {
        let normalizedTitle = normalized(title) ?? "Manual Recipe"
        let normalizedDetails = normalized(details) ?? "Recipe details"
        pendingSubmission = nil
        pendingManualSubmission = ManualSubmission(
            title: normalizedTitle,
            details: normalizedDetails
        )

        do {
            let recipes = try repository.fetchRecipes()
            let decision = accountSession.saveDecision(
                savedRecipeCount: recipes.count
            )
            switch decision {
            case .allow:
                break
            case .allowWithAccountPrompt where bypassingGuestPrompt:
                break
            case .allowWithAccountPrompt, .limitReached:
                state = .guestLimit(decision)
                return
            }

            var job = ImportJob.queued(
                sourceURL: URL(
                    string: "https://manual.ladle.local/\(UUID().uuidString)"
                )!,
                source: .other
            )
            job.pastedRecipeText = "\(normalizedTitle)\n\(normalizedDetails)"
            try repository.save(job)
            await process(job)
        } catch {
            state = .persistenceFailed
        }
    }

    func reimport(
        recipe: Recipe,
        correctionNotes: String? = nil
    ) async {
        existingDuplicate = nil
        completedRecipe = nil
        pendingSubmission = nil
        pendingManualSubmission = nil

        var job = ImportJob.reimporting(
            sourceURL: recipe.originalURL,
            source: recipe.source,
            currentRecipeID: recipe.id,
            candidateRecipeID: UUID()
        )
        job.correctionNotes = normalized(correctionNotes)

        do {
            try repository.save(job)
            await processReimport(job)
        } catch {
            state = .persistenceFailed
        }
    }

    func reset() {
        state = .idle
        existingDuplicate = nil
        completedRecipe = nil
        pendingSubmission = nil
        pendingManualSubmission = nil
    }

    private func process(_ initialJob: ImportJob) async {
        var job = initialJob
        state = .importing(jobID: job.id)

        do {
            try await clock.sleep(for: parsingDelay)
            let outcome = try await service.importRecipe(for: job)
            try Task.checkCancellation()

            switch outcome {
            case let .ready(recipe):
                try repository.save(recipe)
                job = try job.transitioning(to: .ready)
                try repository.save(job)
                completedRecipe = recipe
                state = .completed(recipeID: recipe.id)
            case let .needsReview(recipe):
                try repository.save(recipe)
                job = try job.transitioning(to: .needsReview)
                try repository.save(job)
                completedRecipe = recipe
                state = .needsReview(recipeID: recipe.id)
            case let .failed(reason):
                job = try job.transitioning(to: .failed(reason))
                try repository.save(job)
                state = .failed(jobID: job.id, reason: reason)
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            do {
                job = try job.transitioning(
                    to: .failed(.networkUnavailable)
                )
                try repository.save(job)
                state = .failed(
                    jobID: job.id,
                    reason: .networkUnavailable
                )
            } catch {
                state = .persistenceFailed
            }
        }
    }

    private func processReimport(_ initialJob: ImportJob) async {
        var job = initialJob
        state = .importing(jobID: job.id)

        do {
            try await clock.sleep(for: parsingDelay)
            let outcome = try await service.importRecipe(for: job)
            try Task.checkCancellation()

            switch outcome {
            case let .ready(candidate):
                guard let candidateID = job.candidateRecipeID,
                      let currentRecipeID = job.currentRecipeID,
                      candidate.id == candidateID else {
                    state = .persistenceFailed
                    return
                }
                try repository.save(candidate)
                job = try job.transitioning(to: .ready)
                try repository.save(job)
                try repository.deleteRecipe(id: currentRecipeID)
                completedRecipe = candidate
                state = .completed(recipeID: candidate.id)
            case let .needsReview(candidate):
                guard candidate.id == job.candidateRecipeID else {
                    state = .persistenceFailed
                    return
                }
                job = try job.transitioning(to: .needsReview)
                try repository.save(job)
                completedRecipe = candidate
                state = .needsReview(recipeID: candidate.id)
            case let .failed(reason):
                job = try job.transitioning(to: .failed(reason))
                try repository.save(job)
                completedRecipe = nil
                state = .failed(jobID: job.id, reason: reason)
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            do {
                job = try job.transitioning(
                    to: .failed(.networkUnavailable)
                )
                try repository.save(job)
                completedRecipe = nil
                state = .failed(
                    jobID: job.id,
                    reason: .networkUnavailable
                )
            } catch {
                state = .persistenceFailed
            }
        }
    }

    private func makeSubmission(urlText: String) throws -> Submission {
        let trimmed = urlText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw ImportValidationError.invalidURL
        }

        let source: RecipeSource
        if matches(host: host, domain: "tiktok.com") {
            source = .tiktok
        } else if matches(host: host, domain: "instagram.com") {
            source = .instagram
        } else if matches(host: host, domain: "youtube.com")
            || host == "youtu.be" {
            source = .youtube
        } else {
            throw ImportValidationError.unsupportedSource
        }

        return Submission(url: canonicalURL(url), source: source)
    }

    private func matches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }

    private func canonicalURL(_ url: URL) -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return url
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url ?? url
    }

    private func normalized(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return nil
        }
        return value
    }
}
