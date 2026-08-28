import LadleCore
import SwiftUI

struct ReimportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let currentRecipe: Recipe
    @Bindable var coordinator: ImportCoordinator
    let didReplace: (Recipe) -> Void

    @State private var correctionNotes = ""

    var body: some View {
        NavigationStack {
            content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LadleTheme.Surface.porcelain)
            .accessibilityIdentifier("recipe.reimport")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: close)
                        .disabled(isOwnedImporting)
                        .padding(
                            .leading,
                            LadleTheme.Layout.sheetToolbarInset
                        )
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LadleTheme.Surface.porcelain)
        .interactiveDismissDisabled(
            isOwnedImporting || isDecisionPending
        )
        .onAppear {
            if let operation = coordinator.operation,
               !operation.isReimport,
               !coordinator.isImporting {
                coordinator.reset()
            }
            if coordinator.operation == nil {
                coordinator.reset()
                coordinator.resumePendingReimport(for: currentRecipe.id)
            }
            // A resume-adopted reimport has no presentation until this
            // sheet appears; attaching keeps its terminal outcome
            // rendered here instead of self-releasing under the user.
            coordinator.attachReimport(for: currentRecipe.id)
        }
    }

    @ViewBuilder
    private var content: some View {
        if coordinator.operation != nil,
           !coordinator.ownsReimport(for: currentRecipe.id) {
            unavailableContent
        } else if coordinator.state == .persistenceFailed {
            persistenceFailureContent
        } else if coordinator.operation == nil {
            formContent
        } else {
            switch coordinator.state {
            case .importing:
                importingContent
            case .completed:
                decisionContent(requiresReview: false)
            case .needsReview:
                decisionContent(requiresReview: true)
            case .failed:
                failedContent
            case .cancelled:
                cancelledContent
            case .persistenceFailed:
                persistenceFailureContent
            case .idle, .validationFailed, .duplicate, .guestLimit:
                formContent
            }
        }
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LadleTheme.Layout.sectionGap) {
                sheetHeader(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Re-import safely",
                    message:
                        "Your current recipe stays available until the replacement is ready."
                )

                VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                    Text("Original source")
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.Label.primary.opacity(0.56))
                    Text(currentRecipe.originalURL.absoluteString)
                        .ladleFont(.body)
                        .foregroundStyle(LadleTheme.Label.primary)
                        .textSelection(.enabled)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LadleTheme.Surface.raised,
                    in: RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.card,
                        style: .continuous
                    )
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Correction notes")
                        .ladleFont(.bodyStrong)
                        .foregroundStyle(LadleTheme.Label.primary)
                    TextEditor(text: $correctionNotes)
                        .ladleFont(.body)
                        .scrollContentBackground(.hidden)
                        .padding(LadleTheme.Spacing.medium)
                        .frame(minHeight: 150)
                        .background(
                            LadleTheme.Surface.raised,
                            in: RoundedRectangle(
                                cornerRadius: LadleTheme.Corner.control,
                                style: .continuous
                            )
                        )
                        .accessibilityLabel("Correction notes")
                    Text(
                        "Optional: mention anything the first import missed or misunderstood."
                    )
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.primary.opacity(0.56))
                }

                Button("Start safe re-import") {
                    Task {
                        await coordinator.reimport(
                            recipe: currentRecipe,
                            correctionNotes: correctionNotes
                        )
                    }
                }
                .buttonStyle(LadleButtonStyle(role: .primary))
            }
            .padding(LadleTheme.Spacing.generous)
        }
        .scrollIndicators(.hidden)
    }

    private var importingContent: some View {
        VStack(spacing: LadleTheme.Layout.sectionGap) {
            ProgressView()
                .controlSize(.large)
                .tint(LadleTheme.Intent.accent)
            Text("Building a replacement")
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.Label.primary)
            Text(
                "\(currentRecipe.title) is still saved and ready to use while Overeasy checks the source."
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.Label.primary.opacity(0.64))
            .multilineTextAlignment(.center)
        }
        .padding(LadleTheme.Spacing.generous)
    }

    private func decisionContent(requiresReview: Bool) -> some View {
        ReimportDecisionView(
            currentRecipe: currentRecipe,
            candidate: coordinator.completedRecipe,
            requiresReview: requiresReview,
            accept: acceptCandidate,
            keepCurrent: keepCurrent
        )
    }

    private var failedContent: some View {
        resultContent(
            icon: "shield.checkered",
            title: "Current recipe is safe",
            message: currentRecipe.title,
            buttonTitle: "Try re-import again",
            action: {
                guard case let .failed(jobID, _) = coordinator.state else {
                    coordinator.reset()
                    return
                }
                Task {
                    await coordinator.retry(
                        jobID: jobID,
                        correctionNotes: correctionNotes
                    )
                }
            }
        )
    }

    private var persistenceFailureContent: some View {
        resultContent(
            icon: "exclamationmark.triangle",
            title: "Re-import couldn’t start",
            message:
                "The current recipe is unchanged. Close this sheet and try again.",
            buttonTitle: "Close",
            action: close
        )
    }

    private var cancelledContent: some View {
        resultContent(
            icon: "xmark.circle",
            title: "Re-import cancelled",
            message:
                "This re-import was cancelled. Your current recipe is unchanged.",
            buttonTitle: "Close",
            action: close
        )
    }

    private func resultContent(
        icon: String,
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: LadleTheme.Layout.sectionGap) {
            Image(systemName: icon)
                .font(.system(size: LadleTheme.IconSize.feature, weight: .bold))
                .foregroundStyle(LadleTheme.Label.onAccent)
                .frame(width: 62, height: 62)
                .background(LadleTheme.Intent.accent, in: Circle())
            Text(title)
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.Label.primary)
                .multilineTextAlignment(.center)
            Text(message)
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.Label.primary.opacity(0.64))
                .multilineTextAlignment(.center)
            Button(buttonTitle, action: action)
                .buttonStyle(LadleButtonStyle(role: .primary))
        }
        .padding(LadleTheme.Spacing.generous)
    }

    private func sheetHeader(
        icon: String,
        title: String,
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
            Image(systemName: icon)
                .font(.system(size: LadleTheme.IconSize.large, weight: .semibold))
                .foregroundStyle(LadleTheme.Label.accent)
                .frame(width: 50, height: 50)
                .background(LadleTheme.Surface.badge, in: Circle())
            Text(title)
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.Label.primary)
            Text(message)
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.Label.primary.opacity(0.64))
        }
    }

    private var isDecisionPending: Bool {
        coordinator.ownsReimport(for: currentRecipe.id)
            && coordinator.state.isReplacementDecision
    }

    private var isOwnedImporting: Bool {
        coordinator.ownsReimport(for: currentRecipe.id)
            && coordinator.isImporting
    }

    private func acceptCandidate() {
        Task {
            if let replacement =
                await coordinator.acceptReplacementCandidate() {
                didReplace(replacement)
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
            // The same release the presentation's onDismiss runs for a
            // swipe-down, so the two dismissals cannot behave differently.
            coordinator.releaseReimport(for: currentRecipe.id)
            dismiss()
        }
    }

    private var unavailableContent: some View {
        resultContent(
            icon: "hourglass",
            title: "Another import is active",
            message:
                "Finish or review that import before replacing this recipe.",
            buttonTitle: "Close",
            action: dismiss.callAsFunction
        )
    }
}

struct ReimportDecisionView: View {
    let currentRecipe: Recipe
    let candidate: Recipe?
    let requiresReview: Bool
    let accept: () -> Void
    let keepCurrent: () -> Void
    @State private var isResolving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LadleTheme.Layout.sectionGap) {
                header
                currentRecipeNotice

                if let candidate {
                    Text(candidate.title)
                        .ladleFont(.title)
                        .foregroundStyle(LadleTheme.Label.primary)
                    RecipeMetadataBand(recipe: candidate)
                    IngredientList(
                        ingredients: candidate.orderedIngredients
                    )
                    MethodList(steps: candidate.orderedSteps)

                    Button(
                        requiresReview
                            ? "Use reviewed candidate"
                            : "Use updated recipe"
                    ) {
                        isResolving = true
                        accept()
                    }
                    .buttonStyle(LadleButtonStyle(role: .primary))
                }

                Button("Keep current recipe") {
                    isResolving = true
                    keepCurrent()
                }
                .buttonStyle(LadleButtonStyle(role: .secondary))
            }
            .padding(LadleTheme.Spacing.generous)
            .disabled(isResolving)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
            Image(
                systemName: requiresReview
                    ? "pencil.and.list.clipboard"
                    : "checkmark"
            )
            .font(.system(size: LadleTheme.IconSize.large, weight: .semibold))
            .foregroundStyle(LadleTheme.Label.accent)
            .frame(width: 50, height: 50)
            .background(LadleTheme.Surface.badge, in: Circle())
            Text(
                requiresReview
                    ? "Review the replacement"
                    : "Updated recipe ready"
            )
            .ladleFont(.title)
            .foregroundStyle(LadleTheme.Label.primary)
            Text(
                "Your current recipe stays available until you accept this candidate."
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.Label.primary.opacity(0.64))
        }
    }

    private var currentRecipeNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.checkered")
                .foregroundStyle(LadleTheme.Label.accent)
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                Text("Current recipe is safe")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.primary)
                Text(currentRecipe.title)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.secondary)
            }
        }
        .padding(LadleTheme.Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LadleTheme.Surface.steel,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
        )
    }
}
