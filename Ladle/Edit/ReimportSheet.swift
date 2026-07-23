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
            Group {
                switch coordinator.state {
                case .importing:
                    importingContent
                case .completed:
                    successContent
                case .needsReview:
                    needsReviewContent
                case .failed:
                    failedContent
                case .persistenceFailed:
                    persistenceFailureContent
                case .idle, .validationFailed, .duplicate, .guestLimit:
                    formContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LadleTheme.paper)
            .accessibilityIdentifier("recipe.reimport")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LadleTheme.paper)
        .onAppear {
            if !coordinator.isImporting {
                coordinator.reset()
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
                        if case .completed = coordinator.state,
                           let replacement = coordinator.completedRecipe {
                            didReplace(replacement)
                        }
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
                "\(currentRecipe.title) is still saved and ready to use while Ladle checks the source."
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.ink.opacity(0.64))
            .multilineTextAlignment(.center)
        }
        .padding(LadleTheme.Spacing.generous)
    }

    private var successContent: some View {
        resultContent(
            icon: "checkmark",
            title: "Updated recipe ready",
            message:
                coordinator.completedRecipe?.title ?? currentRecipe.title,
            buttonTitle: "Use updated recipe",
            action: {
                if let replacement = coordinator.completedRecipe {
                    didReplace(replacement)
                }
                dismiss()
            }
        )
    }

    private var needsReviewContent: some View {
        resultContent(
            icon: "pencil.and.list.clipboard",
            title: "Candidate needs a review",
            message:
                "The current recipe is still safe. Review support will let you compare this candidate before replacing it.",
            buttonTitle: "Keep current recipe",
            action: {
                dismiss()
            }
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
                    applyCompletedRecipeIfNeeded()
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
            action: {
                dismiss()
            }
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

    private func applyCompletedRecipeIfNeeded() {
        if case .completed = coordinator.state,
           let replacement = coordinator.completedRecipe {
            didReplace(replacement)
        }
    }
}
