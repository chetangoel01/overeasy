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
            .background(LadleTheme.Surface.porcelain)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: close)
                        .disabled(isRetrying || isOwnedImporting)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(LadleTheme.Surface.porcelain)
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
                VStack(alignment: .leading, spacing: LadleTheme.Layout.sectionGap) {
                    header
                    savedLink
                    ImportRecoveryActions(
                        isRetrying: isRetrying,
                        retryAvailability: currentFailure.retryAvailability(),
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
            Image(
                systemName: currentFailure.report?.failure.systemImage
                    ?? "exclamationmark.triangle.fill"
            )
                .font(.system(size: 22))
                .foregroundStyle(LadleTheme.Label.accent)
                .frame(width: 52, height: 52)
                .background(LadleTheme.Surface.steel, in: Circle())

            Text(currentFailure.title)
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.Label.primary)

            Text(failureMessage)
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.Label.primary.opacity(0.64))
        }
    }

    private var savedLink: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved link")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.primary.opacity(0.56))
            Text(job.sourceURL.absoluteString)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.primary)
                .textSelection(.enabled)
        }
        .padding(LadleTheme.Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LadleTheme.Surface.raised, in: RoundedRectangle(cornerRadius: 14))
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
        .foregroundStyle(LadleTheme.Label.primary)
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
        return currentFailure.message
    }

    private var currentFailure: ImportOperationFailure {
        if let failure = coordinator.failure(for: job) {
            return failure
        }
        return ImportOperationFailure(
            jobID: job.id,
            reason: .parserUnavailable
        )
    }
}
