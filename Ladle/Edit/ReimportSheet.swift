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
            .background(LadleTheme.paper)
            .accessibilityIdentifier("recipe.reimport")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: close)
                        .disabled(isOwnedImporting)
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LadleTheme.paper)
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
            case .persistenceFailed:
                persistenceFailureContent
            case .idle, .validationFailed, .duplicate, .guestLimit:
                formContent
            }
        }
    }

    private var formContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                sheetHeader(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Re-import safely",
                    message:
                        "Your current recipe stays available until the replacement is ready."
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text("Original source")
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.ink.opacity(0.56))
                    Text(currentRecipe.originalURL.absoluteString)
                        .ladleFont(.body)
                        .foregroundStyle(LadleTheme.ink)
                        .textSelection(.enabled)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LadleTheme.field,
                    in: RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.card,
                        style: .continuous
                    )
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Correction notes")
                        .ladleFont(.bodyStrong)
                        .foregroundStyle(LadleTheme.ink)
                    TextEditor(text: $correctionNotes)
                        .ladleFont(.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 150)
                        .background(
                            LadleTheme.field,
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
                    .foregroundStyle(LadleTheme.ink.opacity(0.56))
                }

                Button("Start safe re-import") {
                    Task {
                        await coordinator.reimport(
                            recipe: currentRecipe,
                            correctionNotes: correctionNotes
                        )
                    }
                }
                .buttonStyle(LadlePrimaryButtonStyle())
            }
            .padding(LadleTheme.Spacing.generous)
        }
        .scrollIndicators(.hidden)
    }

    private var importingContent: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
                .tint(LadleTheme.paprika)
            Text("Building a replacement")
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.ink)
            Text(
                "\(currentRecipe.title) is still saved and ready to use while Overeasy checks the source."
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.ink.opacity(0.64))
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

    private func resultContent(
        icon: String,
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 62, height: 62)
                .background(LadleTheme.paprika, in: Circle())
            Text(title)
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.ink.opacity(0.64))
                .multilineTextAlignment(.center)
            Button(buttonTitle, action: action)
                .buttonStyle(LadlePrimaryButtonStyle())
        }
        .padding(LadleTheme.Spacing.generous)
    }

    private func sheetHeader(
        icon: String,
        title: String,
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 50, height: 50)
                .background(LadleTheme.review, in: Circle())
            Text(title)
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.ink)
            Text(message)
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.ink.opacity(0.64))
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
            if coordinator.ownsReimport(for: currentRecipe.id) {
                coordinator.reset()
            }
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
            VStack(alignment: .leading, spacing: 22) {
                header
                currentRecipeNotice

                if let candidate {
                    Text(candidate.title)
                        .ladleFont(.title)
                        .foregroundStyle(LadleTheme.ink)
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
                    .buttonStyle(LadlePrimaryButtonStyle())
                }

                Button("Keep current recipe") {
                    isResolving = true
                    keepCurrent()
                }
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(LadleTheme.Spacing.generous)
            .disabled(isResolving)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(
                systemName: requiresReview
                    ? "pencil.and.list.clipboard"
                    : "checkmark"
            )
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(LadleTheme.paprika)
            .frame(width: 50, height: 50)
            .background(LadleTheme.review, in: Circle())
            Text(
                requiresReview
                    ? "Review the replacement"
                    : "Updated recipe ready"
            )
            .ladleFont(.title)
            .foregroundStyle(LadleTheme.ink)
            Text(
                "Your current recipe stays available until you accept this candidate."
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.ink.opacity(0.64))
        }
    }

    private var currentRecipeNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.checkered")
                .foregroundStyle(LadleTheme.paprika)
            VStack(alignment: .leading, spacing: 3) {
                Text("Current recipe is safe")
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                Text(currentRecipe.title)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.mutedInk)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LadleTheme.review,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
        )
    }
}
