import LadleCore
import SwiftUI

struct FailedImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let job: ImportJob
    @Bindable var coordinator: ImportCoordinator
    let viewRecipe: (Recipe, String) -> Void

    @State private var recoveryInputMode: RecoveryInputMode?
    @State private var isRetrying = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    savedLink
                    recoveryActions
                }
                .padding(LadleTheme.Spacing.generous)
            }
            .scrollIndicators(.hidden)
            .background(LadleTheme.paper)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(LadleTheme.paper)
        .sheet(item: $recoveryInputMode) { mode in
            CorrectionNotesView(mode: mode) { notes, pastedText in
                runRetry(
                    correctionNotes: notes,
                    pastedRecipeText: pastedText
                )
            }
        }
        .onAppear {
            coordinator.reset()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 52, height: 52)
                .background(LadleTheme.review, in: Circle())

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

    private var recoveryActions: some View {
        VStack(spacing: 10) {
            Button {
                runRetry()
            } label: {
                if isRetrying {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Retry Import")
                }
            }
            .buttonStyle(LadlePrimaryButtonStyle())
            .disabled(isRetrying)

            recoveryButton(
                title: "Add correction notes",
                systemImage: "text.bubble",
                mode: .correctionNotes
            )
            recoveryButton(
                title: "Paste recipe details",
                systemImage: "doc.on.clipboard",
                mode: .pastedDetails
            )
            recoveryButton(
                title: "Create manually",
                systemImage: "square.and.pencil",
                mode: .manual
            )
        }
    }

    private func recoveryButton(
        title: String,
        systemImage: String,
        mode: RecoveryInputMode
    ) -> some View {
        Button {
            recoveryInputMode = mode
        } label: {
            Label(title, systemImage: systemImage)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(
                    LadleTheme.field,
                    in: RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.control,
                        style: .continuous
                    )
                )
        }
    }

    private func runRetry(
        correctionNotes: String? = nil,
        pastedRecipeText: String? = nil
    ) {
        isRetrying = true
        Task {
            await coordinator.retry(
                jobID: job.id,
                correctionNotes: correctionNotes,
                pastedRecipeText: pastedRecipeText
            )
            isRetrying = false
            if let recipe = coordinator.completedRecipe {
                viewRecipe(recipe, "Imported recipe")
                dismiss()
            }
        }
    }

    private var failureMessage: String {
        guard case let .failed(reason) = job.status else {
            return "The import stopped, but the original link is safe."
        }
        switch reason {
        case .privateOrDeleted:
            return "The post may be private or deleted. Add any details you can see, or create the recipe manually."
        case .networkUnavailable:
            return "The connection dropped while Ladle was working. Retrying is safe."
        case .unsupportedSource:
            return "That source isn’t supported yet, but you can keep the link and create the recipe manually."
        case .invalidURL:
            return "The saved link is incomplete. Paste the recipe details or create it manually."
        case .parserUnavailable:
            return "Ladle couldn’t read this video. Retry, add a note, paste the details, or create it manually."
        }
    }
}
