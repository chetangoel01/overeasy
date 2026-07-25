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

enum ImportOperation: Equatable {
    case importJob(UUID)
    case reimport(jobID: UUID, currentRecipeID: UUID)

    var jobID: UUID {
        switch self {
        case let .importJob(jobID), let .reimport(jobID, _):
            jobID
        }
    }

    var isReimport: Bool {
        if case .reimport = self { true } else { false }
    }
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
    private enum RemoteOperation {
        case submit(allowingDuplicate: Bool)
        case resume
        case retry
    }

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

    @ObservationIgnored
    private let notificationService: NotificationService

    @ObservationIgnored
    private let didCompleteRemoteImport:
        @MainActor @Sendable () async -> Void

    private let parsingDelay: Duration
    private var pendingSubmission: Submission?
    private var pendingManualSubmission: ManualSubmission?
    private var isResolvingReplacement = false

    private(set) var state: ImportCoordinatorState = .idle
    private(set) var operation: ImportOperation?
    private(set) var existingDuplicate: Recipe?
    private(set) var completedRecipe: Recipe?

    init(
        repository: RecipeRepository,
        service: any ImportService,
        accountSession: AccountSession,
        clock: any ImportClock = ContinuousImportClock(),
        parsingDelay: Duration = .milliseconds(450),
        notificationService: NotificationService =
            DisabledNotificationService(),
        didCompleteRemoteImport:
            @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.repository = repository
        self.service = service
        self.accountSession = accountSession
        self.clock = clock
        self.parsingDelay = parsingDelay
        self.notificationService = notificationService
        self.didCompleteRemoteImport = didCompleteRemoteImport
    }

    var isImporting: Bool {
        if case .importing = state {
            true
        } else {
            false
        }
    }

    func owns(jobID: UUID) -> Bool {
        operation?.jobID == jobID
    }

    func ownsReimport(for recipeID: UUID) -> Bool {
        guard case let .reimport(_, currentRecipeID) = operation else {
            return false
        }
        return currentRecipeID == recipeID
    }

    func submit(
        urlText: String,
        allowingDuplicate: Bool = false,
        bypassingGuestPrompt: Bool = false
    ) async {
        guard operation?.isReimport != true, !isImporting else {
            return
        }
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
            operation = .importJob(job.id)
            await process(
                job,
                operation: .submit(
                    allowingDuplicate: allowingDuplicate
                )
            )
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
        guard operation == nil || owns(jobID: jobID) else {
            return
        }
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

            let currentRecipeID = job.currentRecipeID
            operation = currentRecipeID.map {
                .reimport(
                    jobID: job.id,
                    currentRecipeID: $0
                )
            } ?? .importJob(job.id)
            if currentRecipeID != nil {
                job = try job.retryingReimport(
                    candidateRecipeID: UUID()
                )
            } else {
                job = try job.transitioning(to: .parsing)
            }
            try repository.save(job)
            await process(job, operation: .retry)
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
        guard operation?.isReimport != true, !isImporting else {
            return
        }
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

            let recipeID = UUID()
            let now = Date.now
            let recipe = Recipe(
                id: recipeID,
                title: normalizedTitle,
                description: normalizedDetails,
                source: .other,
                originalURL: URL(
                    string:
                        "https://manual.ladle.local/\(recipeID.uuidString.lowercased())"
                )!,
                servings: 1,
                createdAt: now,
                updatedAt: now
            )
            try repository.save(recipe)
            completedRecipe = recipe
            state = .completed(recipeID: recipe.id)
            await didCompleteRemoteImport()
        } catch {
            state = .persistenceFailed
        }
    }

    func reimport(
        recipe: Recipe,
        correctionNotes: String? = nil
    ) async {
        guard operation == nil else {
            return
        }
        existingDuplicate = nil
        completedRecipe = nil
        pendingSubmission = nil
        pendingManualSubmission = nil
        isResolvingReplacement = false

        var job = ImportJob.reimporting(
            sourceURL: recipe.originalURL,
            source: recipe.source,
            currentRecipeID: recipe.id,
            candidateRecipeID: UUID()
        )
        job.correctionNotes = normalized(correctionNotes)

        operation = .reimport(
            jobID: job.id,
            currentRecipeID: recipe.id
        )
        do {
            try repository.save(job)
            await process(
                job,
                operation: .submit(allowingDuplicate: true)
            )
        } catch {
            state = .persistenceFailed
        }
    }

    func resumePendingImports() async {
        do {
            let pendingJobs = try repository.fetchImportJobs().filter {
                $0.status == .parsing
            }
            for job in pendingJobs {
                try Task.checkCancellation()
                await process(job, operation: .resume)
            }
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .persistenceFailed
        }
    }

    func reset() {
        state = .idle
        operation = nil
        existingDuplicate = nil
        completedRecipe = nil
        pendingSubmission = nil
        pendingManualSubmission = nil
        isResolvingReplacement = false
    }

    func resumePendingReimport(for currentRecipeID: UUID) {
        guard operation == nil else {
            return
        }
        do {
            guard let job = try repository.fetchImportJobs().last(
                where: {
                    $0.currentRecipeID == currentRecipeID
                        && $0.reviewCandidate != nil
                }
            ), let candidate = job.reviewCandidate else {
                return
            }
            operation = .reimport(
                jobID: job.id,
                currentRecipeID: currentRecipeID
            )
            completedRecipe = candidate
            state = candidate.reviewStatus == .needsReview
                ? .needsReview(recipeID: candidate.id)
                : .completed(recipeID: candidate.id)
        } catch {
            state = .persistenceFailed
        }
    }

    @discardableResult
    func acceptReplacementCandidate() async -> Recipe? {
        guard !isResolvingReplacement,
              operation?.isReimport == true,
              state.isReplacementDecision,
              var candidate = completedRecipe else {
            return nil
        }
        isResolvingReplacement = true
        defer { isResolvingReplacement = false }

        do {
            guard var job = try repository.fetchImportJobs().first(
                where: { $0.candidateRecipeID == candidate.id }
            ), let currentRecipeID = job.currentRecipeID else {
                state = .persistenceFailed
                return nil
            }
            candidate.reviewStatus = .ready
            candidate.updatedAt = .now
            job = try job.transitioning(to: .ready)
            try repository.replaceRecipe(
                id: currentRecipeID,
                with: candidate,
                completing: job
            )
            completedRecipe = candidate
            state = .completed(recipeID: candidate.id)
            _ = await notificationService.notifyImportReady(
                recipe: candidate
            )
            operation = nil
            await didCompleteRemoteImport()
            return candidate
        } catch {
            state = .persistenceFailed
            return nil
        }
    }

    func keepCurrentRecipe() {
        guard !isResolvingReplacement,
              operation?.isReimport == true,
              state.isReplacementDecision,
              let candidateID = completedRecipe?.id else {
            return
        }
        do {
            guard var job = try repository.fetchImportJobs().first(
                where: { $0.candidateRecipeID == candidateID }
            ) else {
                state = .persistenceFailed
                return
            }
            job = try job.keepingCurrentRecipe()
            try repository.save(job)
            completedRecipe = nil
            state = .idle
            operation = nil
        } catch {
            state = .persistenceFailed
        }
    }

    private func process(
        _ initialJob: ImportJob,
        operation: RemoteOperation
    ) async {
        var job = initialJob
        state = .importing(jobID: job.id)

        do {
            var update = try await firstUpdate(
                for: job,
                operation: operation
            )
            job.remoteJobID = update.remoteJobID
            try repository.save(job)

            var delay = parsingDelay
            while update.progress == .parsing {
                try await clock.sleep(for: delay)
                try Task.checkCancellation()
                update = try await service.status(
                    remoteJobID: update.remoteJobID
                )
                job.remoteJobID = update.remoteJobID
                try repository.save(job)
                delay = min(delay * 2, .seconds(30))
            }

            try Task.checkCancellation()
            try await apply(update, to: &job)
        } catch is CancellationError {
            state = .idle
        } catch let APIError.remote(error) {
            handleRemoteError(error, job: &job)
        } catch {
            state = .failed(
                jobID: job.id,
                reason: .networkUnavailable
            )
        }
    }

    private func firstUpdate(
        for job: ImportJob,
        operation: RemoteOperation
    ) async throws -> ImportServiceUpdate {
        switch operation {
        case let .submit(allowingDuplicate):
            return try await service.submit(
                job,
                allowingDuplicate: allowingDuplicate
            )
        case .resume:
            if let remoteJobID = job.remoteJobID {
                return try await service.status(
                    remoteJobID: remoteJobID
                )
            }
            return try await service.submit(
                job,
                allowingDuplicate: false
            )
        case .retry:
            if let remoteJobID = job.remoteJobID {
                return try await service.retry(
                    remoteJobID: remoteJobID,
                    correctionNotes: job.correctionNotes,
                    pastedRecipeText: job.pastedRecipeText
                )
            }
            return try await service.submit(
                job,
                allowingDuplicate: job.currentRecipeID != nil
            )
        }
    }

    private func apply(
        _ update: ImportServiceUpdate,
        to job: inout ImportJob
    ) async throws {
        switch update.progress {
        case .parsing:
            return
        case let .ready(recipe):
            if job.currentRecipeID != nil {
                guard recipe.id == job.candidateRecipeID else {
                    state = .persistenceFailed
                    return
                }
                job = try job.awaitingReview(candidate: recipe)
                try repository.save(job)
                completedRecipe = recipe
                state = .completed(recipeID: recipe.id)
                return
            }
            job = try job.transitioning(to: .ready)
            if let serverRevision = update.serverRevision {
                try repository.saveRemote(
                    recipe,
                    revision: serverRevision
                )
            } else {
                try repository.save(recipe)
            }
            try repository.save(job)
            completedRecipe = recipe
            state = .completed(recipeID: recipe.id)
            _ = await notificationService.notifyImportReady(
                recipe: recipe
            )
            await didCompleteRemoteImport()
        case let .needsReview(recipe):
            if job.currentRecipeID != nil {
                guard recipe.id == job.candidateRecipeID else {
                    state = .persistenceFailed
                    return
                }
                job = try job.awaitingReview(candidate: recipe)
                try repository.save(job)
                completedRecipe = recipe
                state = .needsReview(recipeID: recipe.id)
                return
            }
            if let serverRevision = update.serverRevision {
                try repository.saveRemote(
                    recipe,
                    revision: serverRevision
                )
            } else {
                try repository.save(recipe)
            }
            job = try job.transitioning(to: .needsReview)
            try repository.save(job)
            completedRecipe = recipe
            state = .needsReview(recipeID: recipe.id)
            await didCompleteRemoteImport()
        case let .failed(reason):
            job = try job.transitioning(to: .failed(reason))
            try repository.save(job)
            completedRecipe = nil
            state = .failed(jobID: job.id, reason: reason)
        }
    }

    private func handleRemoteError(
        _ error: RemoteErrorDTO,
        job: inout ImportJob
    ) {
        switch (error.code, error.details) {
        case let (
            .duplicateRecipe,
            .duplicate(existingRecipeID)
        ):
            do {
                existingDuplicate = try repository.fetchRecipe(
                    id: existingRecipeID
                )
                try repository.deleteImportJob(id: job.id)
                state = .duplicate(existingRecipeID: existingRecipeID)
            } catch {
                state = .persistenceFailed
            }
        case (.guestRecipeLimitReached, _):
            do {
                try repository.deleteImportJob(id: job.id)
                state = .guestLimit(.limitReached)
            } catch {
                state = .persistenceFailed
            }
        case (.invalidURL, _):
            finishRemoteFailure(.invalidURL, job: &job)
        case (.unsupportedSource, _):
            finishRemoteFailure(.unsupportedSource, job: &job)
        default:
            state = .failed(
                jobID: job.id,
                reason: .networkUnavailable
            )
        }
    }

    private func finishRemoteFailure(
        _ reason: ImportFailure,
        job: inout ImportJob
    ) {
        do {
            job = try job.transitioning(to: .failed(reason))
            try repository.save(job)
            state = .failed(jobID: job.id, reason: reason)
        } catch {
            state = .persistenceFailed
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

extension ImportCoordinatorState {
    var isReplacementDecision: Bool {
        switch self {
        case .completed, .needsReview:
            true
        default:
            false
        }
    }
}
