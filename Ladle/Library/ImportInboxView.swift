import LadleCore
import SwiftUI

struct ImportInboxView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var viewModel: LibraryViewModel
    let addRecipe: () -> Void
    let recoverImport: (ImportJob) -> Void
    let openProcessing: (ImportJob) -> Void
    let cancelImport: (UUID) -> Void
    let openReview: (Recipe, String) -> Void
    var operationFailure: (ImportJob) -> ImportOperationFailure? = { _ in nil }
    var canImport = true

    @State private var importAwaitingCancellation: ImportJob?

    var body: some View {
        List {
            jobs
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(LadleTheme.Surface.porcelain)
        .animation(
            reduceMotion
                ? nil
                : .snappy(duration: 0.2, extraBounce: 0),
            value: viewModel.actionableImportJobs.map(\.id)
        )
        .accessibilityIdentifier("library.import-inbox.root")
        .confirmationDialog(
            "Cancel this import?",
            isPresented: cancelConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            Button("Cancel Import", role: .destructive) {
                guard let job = importAwaitingCancellation else { return }
                cancelImport(job.id)
                importAwaitingCancellation = nil
            }
            Button("Keep Processing", role: .cancel) {
                importAwaitingCancellation = nil
            }
        } message: {
            Text("The recipe will stop processing and disappear from Inbox.")
        }
    }

    @ViewBuilder
    private var jobs: some View {
        if viewModel.actionableImportJobs.isEmpty {
            // The same state view the Recipes tab uses for "No recipes yet",
            // so the two empty states share one shape and one filled primary
            // button. A system placeholder put the secondary role in a small
            // grey lozenge that read as disabled.
            LadleStateView(
                systemImage: "checkmark.circle",
                title: "Inbox clear",
                message: "Paste a link to import a recipe.",
                primaryTitle: "Add recipe",
                primaryAction: addRecipe,
                primaryIdentifier: "inbox.empty.add-recipe"
            )
            .disabled(!canImport)
            .listRowInsets(EdgeInsets())
            .listRowBackground(LadleTheme.Surface.porcelain)
            .listRowSeparator(.hidden)
        } else {
            ForEach(viewModel.actionableImportJobs) { job in
                Group {
                    if case .failed = job.status {
                        importButton(job, action: { recoverImport(job) })
                    } else if job.reviewCandidate != nil {
                        importButton(job, action: { recoverImport(job) })
                    } else if let recipe = viewModel.recipeForReview(job) {
                        importButton(
                            job,
                            action: {
                                openReview(recipe, "Check details")
                            }
                        )
                    } else if case .parsing = job.status {
                        importButton(job, action: { openProcessing(job) })
                    } else {
                        importButton(job, action: { recoverImport(job) })
                    }
                }
                .listRowInsets(
                    EdgeInsets(
                        top: 6,
                        leading: LadleTheme.Spacing.regular,
                        bottom: 6,
                        trailing: LadleTheme.Spacing.regular
                    )
                )
                .listRowBackground(LadleTheme.Surface.porcelain)
                .listRowSeparator(.hidden)
                .swipeActions(
                    edge: .trailing,
                    allowsFullSwipe: job.status != .parsing
                ) {
                    if case .parsing = job.status {
                        Button(role: .destructive) {
                            importAwaitingCancellation = job
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                    } else {
                        Button(role: .destructive) {
                            _ = viewModel.deleteImport(jobID: job.id)
                        } label: {
                            Label("Discard", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func importButton(
        _ job: ImportJob,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            PendingImportCard(
                job: job,
                creatorName: viewModel.creatorName(for: job),
                recipeTitle: viewModel.title(for: job),
                operationFailure: operationFailure(job)
            )
        }
        .buttonStyle(.plain)
    }

    private var cancelConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { importAwaitingCancellation != nil },
            set: { if !$0 { importAwaitingCancellation = nil } }
        )
    }

}
