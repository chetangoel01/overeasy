import Foundation
import LadleCore
import Observation

enum ImportValidationError: Error, Equatable {
    case invalidURL
    case unsupportedSource
}

enum ImportRetryAvailability: Equatable {
    case available
    case after(Date)
    case afterCapacityResets
    case afterSignIn
    case manualRecovery

    func allowsRetry(at date: Date = .now) -> Bool {
        switch self {
        case .available:
            true
        case let .after(retryAt):
            date >= retryAt
        case .afterCapacityResets, .afterSignIn, .manualRecovery:
            false
        }
    }

    func buttonTitle(at date: Date = .now) -> String {
        switch self {
        case .available:
            "Retry import"
        case let .after(retryAt):
            if date >= retryAt {
                "Retry import"
            } else {
                "Retry after \(retryAt.formatted(date: .omitted, time: .shortened))"
            }
        case .afterCapacityResets:
            "Retry after capacity resets"
        case .afterSignIn:
            "Sign in to retry"
        case .manualRecovery:
            "Use a recovery option"
        }
    }
}

struct ImportOperationFailure: Equatable {
    let jobID: UUID
    let reason: ImportFailure
    let report: RemoteFailureReport?

    init(
        jobID: UUID,
        reason: ImportFailure,
        report: RemoteFailureReport? = nil
    ) {
        self.jobID = jobID
        self.reason = reason
        self.report = report
    }

    func retryAvailability(at date: Date = .now) -> ImportRetryAvailability {
        if reason == .invalidURL || reason == .unsupportedSource {
            return .manualRecovery
        }
        return switch report?.failure {
        case let .rateLimited(retryAt):
            date >= retryAt ? .available : .after(retryAt)
        case .quotaExceeded:
            .afterCapacityResets
        case .authenticationExpired:
            .afterSignIn
        case .none where reason == .quotaExceeded:
            .afterCapacityResets
        case .none where reason == .authenticationExpired:
            .afterSignIn
        default:
            .available
        }
    }

    var title: String {
        if reason == .invalidURL { return "Incomplete link" }
        if reason == .unsupportedSource { return "Unsupported source" }
        return report?.failure.title ?? reason.recoveryTitle
    }

    var message: String {
        if let report {
            switch report.failure {
            case let .rateLimited(retryAt):
                return "\(report.failure.message) Try again after \(retryAt.formatted(date: .omitted, time: .shortened)). The saved link is safe."
            case .quotaExceeded:
                return "Processing capacity is exhausted. Retry after your quota or provider capacity resets. The saved link is safe."
            case .authenticationExpired:
                return "Sign in again before retrying. The saved link is safe."
            default:
                return "\(report.failure.message) The saved link is safe."
            }
        }
        return reason.recoveryMessage
    }
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
    /// The server reported the job as cancelled. The durable row is gone;
    /// this presents the outcome as a cancellation, not a failure.
    case cancelled(jobID: UUID)
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
    private var processingTasks: [UUID: Task<Void, Never>] = [:]

    /// Latched by `quiesceForSignOut()` and lifted only by
    /// `beginSession()`. Draining alone is not enough: a resume driver
    /// suspended on a drained task resumes during one of sign-out's later
    /// suspension points, re-fetches a row the wipe has not removed yet,
    /// and would start a fresh processing task the drain never saw.
    /// While latched, the coordinator adopts and starts nothing — every
    /// job it could pick up still belongs to the signed-out account.
    private var isSignedOut = false

    /// Whether some sheet is presenting the published reimport
    /// `operation` and will render its terminal outcome. Presentation-
    /// driven entry points (`reimport`, `retry`, `resumePendingReimport`,
    /// the sheet's `attachReimport`) mark it; adoption with no sheet
    /// anywhere leaves it false (`resumePendingImports` after a relaunch,
    /// and `attach(to:)`, whose Add sheet never renders a reimport's
    /// outcome); a dismissal that must leave a live import running
    /// (`releaseReimport`) clears it. Consulted only when a reimport
    /// outcome lands: see `releaseUnpresentedReimport(after:)`.
    private var reimportHasPresentation = false

    /// The sheets currently on screen that render re-import outcomes,
    /// as presentation token → presented recipe ID. Maintained only by
    /// `beginReimportPresentation`/`endReimportPresentation`, the two
    /// halves of the `reimportPresentation` view modifier — so a sheet
    /// cannot register a claim here without carrying the release that
    /// retires it. Deliberately untouched by `reset()`: the map
    /// reflects which sheets exist, which no coordinator state change
    /// alters.
    private var reimportPresentations: [UUID: UUID] = [:]

    private(set) var state: ImportCoordinatorState = .idle
    private(set) var operation: ImportOperation?
    private(set) var existingDuplicate: Recipe?
    private(set) var completedRecipe: Recipe?
    private(set) var operationFailure: ImportOperationFailure?

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

    func failure(for job: ImportJob) -> ImportOperationFailure? {
        if let operationFailure, operationFailure.jobID == job.id {
            return operationFailure
        }
        guard case let .failed(reason) = job.status else { return nil }
        return ImportOperationFailure(jobID: job.id, reason: reason)
    }

    func submit(
        urlText: String,
        allowingDuplicate: Bool = false,
        bypassingGuestPrompt: Bool = false
    ) async {
        guard !isSignedOut, operation?.isReimport != true,
              !isImporting else {
            return
        }
        existingDuplicate = nil
        completedRecipe = nil
        operationFailure = nil
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
            await runProcess(
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
        guard !isSignedOut, operation == nil || owns(jobID: jobID) else {
            return
        }
        completedRecipe = nil
        operationFailure = nil

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
            // Retries only start from a sheet (the reimport sheet or the
            // Inbox's failed-import sheet), so that sheet presents the
            // outcome.
            reimportHasPresentation = currentRecipeID != nil
            if currentRecipeID != nil {
                job = try job.retryingReimport(
                    candidateRecipeID: UUID()
                )
            } else {
                job = try job.transitioning(to: .parsing)
            }
            try repository.save(job)
            await runProcess(job, operation: .retry)
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
        guard !isSignedOut, operation?.isReimport != true,
              !isImporting else {
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
        guard !isSignedOut, operation == nil else {
            return
        }
        existingDuplicate = nil
        completedRecipe = nil
        operationFailure = nil
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
        // Only the reimport sheet's own button starts one.
        reimportHasPresentation = true
        do {
            try repository.save(job)
            await runProcess(
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
            for pending in pendingJobs {
                try Task.checkCancellation()
                // Earlier iterations suspended, and sign-out may have
                // latched in the meantime. The rows this loop would adopt
                // still belong to the signed-out account — the wipe just
                // hasn't reached them yet.
                guard !isSignedOut else { return }
                // A job with a live task is already being driven — usually
                // the foreground import the user is watching. Joining it or
                // re-adopting it would overwrite that operation.
                guard processingTasks[pending.id] == nil else { continue }
                // Earlier iterations awaited, so this job may have been
                // cancelled or finished in the meantime; resume the row as
                // it is now, not as it was fetched.
                guard let job = try repository.fetchImportJobs().first(
                    where: { $0.id == pending.id }
                ), job.status == .parsing else { continue }
                if operation == nil {
                    operation = job.currentRecipeID.map {
                        .reimport(jobID: job.id, currentRecipeID: $0)
                    } ?? .importJob(job.id)
                    // Adopted after a relaunch: no sheet exists anywhere
                    // yet. One that opens attaches through the
                    // coordinator; until then a terminal outcome has no
                    // presentation and releases itself.
                    reimportHasPresentation = false
                }
                await runProcess(job, operation: .resume)
            }
        } catch is CancellationError {
            // Torn down mid-resume; pending jobs stay durable and are
            // picked up on the next activation.
        } catch {
            state = .persistenceFailed
        }
    }

    func reset() {
        state = .idle
        operation = nil
        existingDuplicate = nil
        completedRecipe = nil
        operationFailure = nil
        pendingSubmission = nil
        pendingManualSubmission = nil
        isResolvingReplacement = false
        reimportHasPresentation = false
    }

    func attach(to jobID: UUID) -> Bool {
        guard !isSignedOut else { return false }
        if owns(jobID: jobID), isImporting {
            return true
        }
        do {
            guard let job = try repository.fetchImportJobs().first(
                where: { $0.id == jobID && $0.status == .parsing }
            ) else {
                return false
            }
            operation = job.currentRecipeID.map {
                .reimport(jobID: job.id, currentRecipeID: $0)
            } ?? .importJob(job.id)
            // The Add sheet this attach serves renders a reimport
            // operation only as "Re-import in progress", never its
            // outcome.
            reimportHasPresentation = false
            state = .importing(jobID: job.id)
            return true
        } catch {
            state = .persistenceFailed
            return false
        }
    }

    func cancelImport(jobID: UUID) async {
        // The cancel flag and the row deletion happen with no suspension
        // point between them, so by the time the processing task can run
        // again the cancellation is already durable. Every save in
        // `process` re-checks cancellation, so nothing can resurrect the
        // deleted row.
        processingTasks[jobID]?.cancel()
        let job: ImportJob?
        do {
            job = try repository.fetchImportJobs().first {
                $0.id == jobID
            }
            try repository.deleteImportJob(id: jobID)
        } catch {
            state = .persistenceFailed
            return
        }
        if owns(jobID: jobID) {
            reset()
        }
        if let remoteJobID = job?.remoteJobID, job?.status == .parsing {
            // Best effort: the user's cancel already took effect locally.
            // If this fails (offline, or the remote job just finished) the
            // orphaned remote job ends on its own; surfacing a failure here
            // would contradict the cancel the user watched succeed.
            try? await service.cancel(remoteJobID: remoteJobID)
        }
    }

    /// Sign-out is about to wipe the local store. Cancel every processing
    /// task and wait for each to unwind: a task that survived here would
    /// resume after the wipe still holding the signed-out account's
    /// response, and save that account's rows into the store the next
    /// account inherits. The remote job is left running — it belongs to
    /// the signed-out account's server library, not to this device.
    func quiesceForSignOut() async {
        // Latch before the first suspension point so anything that
        // resumes after it — a resume driver, a stale UI task — sees the
        // gate; the drain below only covers tasks that already exist.
        isSignedOut = true
        while let (jobID, task) = processingTasks.first {
            task.cancel()
            await task.value
            // `runProcess` clears its entry when its own await resumes,
            // but that continuation may still be queued behind this one;
            // remove the entry here so the loop observes progress.
            processingTasks.removeValue(forKey: jobID)
        }
        // Published state still points at the signed-out account's
        // operation and would block or mislabel the next account's first
        // import.
        reset()
    }

    /// The next session is on: every re-entry path — Apple, Google, and
    /// guest — funnels through `LadleRuntime.didAuthenticate`, which
    /// calls this to lift the sign-out latch so the new account's
    /// imports can run.
    func beginSession() {
        isSignedOut = false
    }

    func resumePendingReimport(for currentRecipeID: UUID) {
        guard !isSignedOut, operation == nil else {
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
            // Only the reimport sheet's onAppear resumes a decision.
            reimportHasPresentation = true
            completedRecipe = candidate
            state = candidate.reviewStatus == .needsReview
                ? .needsReview(recipeID: candidate.id)
                : .completed(recipeID: candidate.id)
        } catch {
            state = .persistenceFailed
        }
    }

    /// The reimport sheet for `recipeID` is gone — Close, or a swipe-down
    /// that runs no view cleanup of its own. `finishRemoteCancellation`
    /// and the failure paths deliberately keep `operation` so the sheet
    /// can present the outcome; once the sheet is dismissed, an owned
    /// reimport that is no longer running must not stay published, or it
    /// wedges the Add Recipe sheet behind "Re-import in progress" with
    /// nothing left to finish. A live import keeps its state (dismissal
    /// is disabled, and reopening the sheet re-attaches to it); an
    /// operation for another recipe or job is left alone. A pending
    /// decision released here survives durably: `resumePendingReimport`
    /// re-presents it the next time the sheet opens for that recipe.
    func releaseReimport(for recipeID: UUID) {
        guard ownsReimport(for: recipeID) else { return }
        guard !isImporting else {
            // Torn down mid-import (both dismissal affordances are
            // disabled then): the live operation stays for a reopened
            // sheet to re-attach to, but nothing presents it now — if
            // nothing does, its outcome must release itself when it
            // lands.
            reimportHasPresentation = false
            return
        }
        reset()
    }

    /// The reimport sheet for `recipeID` came on screen. A resume-
    /// adopted operation has no presentation until then; attaching keeps
    /// a terminal outcome that lands while the sheet is open published
    /// for the sheet to render, instead of self-releasing under the
    /// user.
    func attachReimport(for recipeID: UUID) {
        guard ownsReimport(for: recipeID) else { return }
        reimportHasPresentation = true
    }

    /// A sheet that renders re-import outcomes for `recipeID` came on
    /// screen; `token` identifies that one presentation until its
    /// paired `endReimportPresentation`. Registering is idempotent and
    /// independent of ownership — the sheet may open before any
    /// operation exists — and also attaches an owned reimport exactly
    /// as `attachReimport` does.
    func beginReimportPresentation(_ token: UUID, for recipeID: UUID) {
        reimportPresentations[token] = recipeID
        attachReimport(for: recipeID)
    }

    /// The presentation identified by `token` left the screen — Close,
    /// a swipe-down, or structural teardown cannot behave differently,
    /// because the `reimportPresentation` modifier runs this for every
    /// disappearance. Once no sheet presents the recipe, the operation
    /// is released through the same `releaseReimport` seam as every
    /// other dismissal; an unknown token (already ended, or never
    /// begun) is a no-op.
    func endReimportPresentation(_ token: UUID) {
        guard let recipeID = reimportPresentations.removeValue(
            forKey: token
        ) else {
            return
        }
        guard !hasReimportPresenter(for: recipeID) else { return }
        releaseReimport(for: recipeID)
    }

    private func hasReimportPresenter(for recipeID: UUID?) -> Bool {
        guard let recipeID else { return false }
        return reimportPresentations.values.contains(recipeID)
    }

    func prepareForNewImport() {
        guard operation?.isReimport == true,
              state.isReplacementDecision else {
            return
        }
        operation = nil
        completedRecipe = nil
        state = .idle
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

    private func runProcess(
        _ job: ImportJob,
        operation: RemoteOperation
    ) async {
        // Structural backstop: every processing task is born here, so no
        // caller — present or future — can start one while sign-out has
        // the coordinator latched.
        guard !isSignedOut else { return }
        if let running = processingTasks[job.id] {
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.process(job, operation: operation)
        }
        processingTasks[job.id] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        processingTasks[job.id] = nil
    }

    private func process(
        _ initialJob: ImportJob,
        operation: RemoteOperation
    ) async {
        var job = initialJob
        if owns(jobID: job.id) {
            state = .importing(jobID: job.id)
            operationFailure = nil
        }

        do {
            var update = try await firstUpdate(
                for: job,
                operation: operation
            )
            // Re-check after every await before touching the store: a
            // cancel may have deleted the row while the response was in
            // flight, and saving would resurrect it.
            try Task.checkCancellation()
            job.remoteJobID = update.remoteJobID
            try repository.save(job)

            var delay = parsingDelay
            while update.progress == .parsing {
                try await clock.sleep(for: delay)
                try Task.checkCancellation()
                update = try await service.status(
                    remoteJobID: update.remoteJobID
                )
                try Task.checkCancellation()
                job.remoteJobID = update.remoteJobID
                try repository.save(job)
                delay = min(delay * 2, .seconds(30))
            }

            try Task.checkCancellation()
            try await apply(update, to: &job)
        } catch is CancellationError {
            finishTaskCancellation(job)
        } catch RemoteContractError.importCancelled {
            finishRemoteCancellation(job)
        } catch let APIError.remote(error) where !Task.isCancelled {
            handleRemoteError(error, job: &job)
        } catch let error as APIError where !Task.isCancelled {
            let report = RemoteFailureReport(error)
            finishRemoteFailure(
                durableReason(for: report.failure),
                report: report,
                job: &job
            )
        } catch {
            // A cancelled task's request can fail with any error type;
            // cancellation decides the outcome, not the error.
            if Task.isCancelled {
                finishTaskCancellation(job)
            } else {
                state = .persistenceFailed
            }
        }
        releaseUnpresentedReimport(after: initialJob.id)
    }

    /// The processing task for the published reimport just landed a
    /// terminal outcome with no sheet anywhere to render it — adopted by
    /// `resumePendingImports` after a relaunch, or its presentation was
    /// torn down mid-import. `releaseReimport` frees the coordinator on
    /// dismissal, but no dismissal can ever come for a sheet that never
    /// existed, and keeping the operation would wedge Add Recipe behind
    /// "Re-import in progress" with nothing left to finish. Everything a
    /// user could still act on is durable — a failed row keeps its Inbox
    /// recovery actions, a pending decision re-presents through
    /// `resumePendingReimport` — so the unpresented outcome releases
    /// here. One with a live sheet stays published for the sheet to
    /// render, and a task torn down before any outcome (`.idle`, its row
    /// still `.parsing`) keeps the operation for the next resume to
    /// drive.
    private func releaseUnpresentedReimport(after jobID: UUID) {
        guard case .reimport = operation, owns(jobID: jobID),
              !reimportHasPresentation,
              !isImporting, state != .idle else {
            return
        }
        reset()
    }

    /// The processing task was torn down — by `cancelImport`, which has
    /// already deleted the row, or by ordinary teardown of whatever awaited
    /// it, which leaves the row `.parsing` for the next resume. Neither is
    /// a failure, and only an operation this coordinator still owns should
    /// see its published state change.
    private func finishTaskCancellation(_ job: ImportJob) {
        guard owns(jobID: job.id) else { return }
        state = .idle
        operationFailure = nil
    }

    /// The server reported the job as cancelled — a cancel from another
    /// session, or an idempotent resubmission matching a job the user had
    /// already cancelled. Drop the durable row so the Inbox honors the
    /// cancellation, and present it as cancelled rather than failed.
    private func finishRemoteCancellation(_ job: ImportJob) {
        do {
            try repository.deleteImportJob(id: job.id)
        } catch {
            state = .persistenceFailed
            return
        }
        guard owns(jobID: job.id) else { return }
        completedRecipe = nil
        operationFailure = nil
        state = .cancelled(jobID: job.id)
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
        // Durable writes and notifications happen for every job; the
        // published state describes only the operation this coordinator
        // owns, so a background job resumed alongside a foreground import
        // cannot steal the sheet the user is watching.
        switch update.progress {
        case .parsing:
            return
        case let .ready(recipe):
            if job.currentRecipeID != nil {
                job = try job.awaitingRemoteReview(candidate: recipe)
                try repository.save(job)
                if owns(jobID: job.id) {
                    completedRecipe = recipe
                    state = .completed(recipeID: recipe.id)
                }
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
            if owns(jobID: job.id) {
                completedRecipe = recipe
                state = .completed(recipeID: recipe.id)
            }
            _ = await notificationService.notifyImportReady(
                recipe: recipe
            )
            await didCompleteRemoteImport()
        case let .needsReview(recipe):
            if job.currentRecipeID != nil {
                job = try job.awaitingRemoteReview(candidate: recipe)
                try repository.save(job)
                if owns(jobID: job.id) {
                    completedRecipe = recipe
                    state = .needsReview(recipeID: recipe.id)
                }
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
            if owns(jobID: job.id) {
                completedRecipe = recipe
                state = .needsReview(recipeID: recipe.id)
            }
            await didCompleteRemoteImport()
        case let .failed(reason):
            job = try job.transitioning(to: .failed(reason))
            try repository.save(job)
            if owns(jobID: job.id) {
                completedRecipe = nil
                state = .failed(jobID: job.id, reason: reason)
                operationFailure = ImportOperationFailure(
                    jobID: job.id,
                    reason: reason
                )
            }
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
                let duplicate = try repository.fetchRecipe(
                    id: existingRecipeID
                )
                try repository.deleteImportJob(id: job.id)
                if owns(jobID: job.id) {
                    existingDuplicate = duplicate
                    state = .duplicate(
                        existingRecipeID: existingRecipeID
                    )
                }
            } catch {
                state = .persistenceFailed
            }
        case (.guestRecipeLimitReached, _):
            do {
                try repository.deleteImportJob(id: job.id)
                if owns(jobID: job.id) {
                    state = .guestLimit(.limitReached)
                }
            } catch {
                state = .persistenceFailed
            }
        case (.invalidURL, _):
            finishRemoteFailure(
                .invalidURL,
                report: RemoteFailureReport(APIError.remote(error)),
                job: &job
            )
        case (.unsupportedSource, _):
            finishRemoteFailure(
                .unsupportedSource,
                report: RemoteFailureReport(APIError.remote(error)),
                job: &job
            )
        default:
            let report = RemoteFailureReport(APIError.remote(error))
            finishRemoteFailure(
                durableReason(for: report.failure),
                report: report,
                job: &job
            )
        }
    }

    private func finishRemoteFailure(
        _ reason: ImportFailure,
        report: RemoteFailureReport? = nil,
        job: inout ImportJob
    ) {
        do {
            job = try job.transitioning(to: .failed(reason))
            try repository.save(job)
            guard owns(jobID: job.id) else { return }
            state = .failed(jobID: job.id, reason: reason)
            operationFailure = ImportOperationFailure(
                jobID: job.id,
                reason: reason,
                report: report
            )
        } catch {
            state = .persistenceFailed
        }
    }

    private func durableReason(for failure: RemoteFailure) -> ImportFailure {
        switch failure {
        case .offline:
            .networkUnavailable
        case .serviceUnavailable, .invalidResponse, .unknown:
            .parserUnavailable
        case .rateLimited, .quotaExceeded:
            .quotaExceeded
        case .authenticationExpired:
            .authenticationExpired
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

extension ImportCoordinator: SessionWriter {}

extension ImportFailure {
    var recoveryTitle: String {
        switch self {
        case .privateOrDeleted:
            "Post unavailable"
        case .unsupportedSource:
            "Unsupported source"
        case .invalidURL:
            "Incomplete link"
        case .networkUnavailable:
            "You're offline"
        case .authenticationExpired:
            "Sign in again"
        case .parserUnavailable:
            "Couldn't read the recipe"
        case .insufficientTextEvidence:
            "More recipe detail needed"
        case .quotaExceeded:
            "Processing limit reached"
        }
    }

    var recoveryMessage: String {
        switch self {
        case .privateOrDeleted:
            "The post may be private or deleted. Add details you can see, or create the recipe manually."
        case .unsupportedSource:
            "That source isn’t supported. Keep the saved link and create the recipe manually."
        case .invalidURL:
            "The saved link is incomplete. Paste recipe details or create the recipe manually."
        case .networkUnavailable:
            "The connection dropped. The saved link is safe to retry."
        case .authenticationExpired:
            "Sign in again before retrying. The saved link is safe."
        case .parserUnavailable:
            "Overeasy couldn’t read the recipe. Retry, add a note, paste details, or create it manually."
        case .insufficientTextEvidence:
            "The post lacks enough written detail. Paste the recipe or create it manually."
        case .quotaExceeded:
            "Processing capacity is exhausted. Retry after your quota or provider capacity resets. The saved link is safe."
        }
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
