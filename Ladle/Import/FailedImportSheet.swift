import LadleCore
import SwiftUI

struct FailedImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let job: ImportJob
    let currentRecipe: Recipe?
    @Bindable var coordinator: ImportCoordinator
    let viewRecipe: (Recipe, String) -> Void

    @State private var recoveryInputMode: RecoveryInputMode?
    @State private var isRetrying = false
    @State private var hasAttemptedRetry = false

    var body: some View {
        NavigationStack {
            content
            .background(LadleTheme.paper)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: close)
                        .disabled(isRetrying || isOwnedImporting)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(LadleTheme.paper)
        .interactiveDismissDisabled(
            isRetrying || isOwnedImporting || isDecisionPending
        )
        .sheet(item: $recoveryInputMode) { mode in
            CorrectionNotesView(mode: mode) { notes, pastedText in
                runRetry(
                    correctionNotes: notes,
                    pastedRecipeText: pastedText
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isDecisionPending,
           let currentRecipe,
           let candidate = coordinator.completedRecipe {
            ReimportDecisionView(
                currentRecipe: currentRecipe,
                candidate: candidate,
                requiresReview: candidate.reviewStatus == .needsReview,
                accept: acceptCandidate,
                keepCurrent: keepCurrent
            )
        } else if coordinator.operation != nil,
                  !coordinator.owns(jobID: job.id) {
            unavailableContent
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    savedLink
                    ImportRecoveryActions(
                        isRetrying: isRetrying,
                        retry: { runRetry() },
                        chooseInput: { recoveryInputMode = $0 }
                    )
                }
                .padding(LadleTheme.Spacing.generous)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 52, height: 52)
                .background(LadleTheme.Surface.steel, in: Circle())

            Text("This recipe needs a hand")
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.ink)

            Text(failureMessage)
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.ink.opacity(0.64))
        }
    }

    private var savedLink: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved link")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.56))
            Text(job.sourceURL.absoluteString)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LadleTheme.field, in: RoundedRectangle(cornerRadius: 14))
    }

    private func runRetry(
        correctionNotes: String? = nil,
        pastedRecipeText: String? = nil
    ) {
        hasAttemptedRetry = true
        isRetrying = true
        Task {
            await coordinator.retry(
                jobID: job.id,
                correctionNotes: correctionNotes,
                pastedRecipeText: pastedRecipeText
            )
            isRetrying = false
            guard job.currentRecipeID == nil,
                  let recipe = coordinator.completedRecipe else {
                return
            }
            switch coordinator.state {
            case .completed:
                viewRecipe(recipe, "Imported recipe")
                coordinator.reset()
                dismiss()
            case .needsReview:
                viewRecipe(recipe, "Check details")
                coordinator.reset()
                dismiss()
            default:
                break
            }
        }
    }

    private var isOwnedImporting: Bool {
        coordinator.owns(jobID: job.id) && coordinator.isImporting
    }

    private var isDecisionPending: Bool {
        job.currentRecipeID != nil
            && coordinator.owns(jobID: job.id)
            && coordinator.state.isReplacementDecision
    }

    private var unavailableContent: some View {
        ContentUnavailableView(
            "Another import is active",
            systemImage: "hourglass",
            description: Text(
                "Finish or review that import before retrying this one."
            )
        )
        .foregroundStyle(LadleTheme.ink)
        .padding(LadleTheme.Spacing.generous)
    }

    private func acceptCandidate() {
        Task {
            if let replacement =
                await coordinator.acceptReplacementCandidate() {
                viewRecipe(replacement, "Updated recipe")
                coordinator.reset()
                dismiss()
            }
        }
    }

    private func keepCurrent() {
        coordinator.keepCurrentRecipe()
        if coordinator.state == .idle {
            dismiss()
        }
    }

    private func close() {
        if isDecisionPending {
            keepCurrent()
        } else {
            if coordinator.owns(jobID: job.id) {
                coordinator.reset()
            }
            dismiss()
        }
    }

    private var failureMessage: String {
        if (hasAttemptedRetry || coordinator.owns(jobID: job.id)),
           coordinator.state == .persistenceFailed {
            return "Overeasy couldn’t save the retry. The original link and current recipe are unchanged."
        }
        let reason: ImportFailure
        if coordinator.owns(jobID: job.id),
           case let .failed(_, latestReason) = coordinator.state {
            reason = latestReason
        } else if case let .failed(originalReason) = job.status {
            reason = originalReason
        } else {
            return "The import stopped, but the original link is safe."
        }
        switch reason {
        case .privateOrDeleted:
            return "The post may be private or deleted. Add any details you can see, or create the recipe manually."
        case .networkUnavailable:
            return "The connection dropped while Overeasy was working. Retrying is safe."
        case .authenticationExpired:
            return "Your session ended while Overeasy was working. Sign in again, then retry this import."
        case .unsupportedSource:
            return "That source isn’t supported yet, but you can keep the link and create the recipe manually."
        case .invalidURL:
            return "The saved link is incomplete. Paste the recipe details or create it manually."
        case .parserUnavailable:
            return "Overeasy couldn’t read this video. Retry, add a note, paste the details, or create it manually."
        case .insufficientTextEvidence:
            return "The post didn’t include enough written recipe detail. Paste the recipe or create it manually."
        case .quotaExceeded:
            return "Overeasy has reached its processing limit. Your link is safe; try again later."
        }
    }
}
