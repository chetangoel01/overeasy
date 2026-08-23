import LadleCore
import SwiftUI

struct ImportInboxView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var viewModel: LibraryViewModel
    let recoverImport: (ImportJob) -> Void
    let openReview: (Recipe, String) -> Void

    var body: some View {
        List {
            jobs
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(LadleTheme.paper)
        .navigationTitle("Import inbox")
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(LadleTheme.paper, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .animation(
            reduceMotion
                ? nil
                : .snappy(duration: 0.2, extraBounce: 0),
            value: viewModel.actionableImportJobs.map(\.id)
        )
        .accessibilityIdentifier("library.import-inbox.root")
    }

    @ViewBuilder
    private var jobs: some View {
        if viewModel.actionableImportJobs.isEmpty {
            ContentUnavailableView(
                "Inbox clear",
                systemImage: "checkmark.circle",
                description: Text(
                    "New imports and anything that needs attention appear here."
                )
            )
            .foregroundStyle(LadleTheme.ink)
            .listRowBackground(LadleTheme.paper)
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
                    } else {
                        PendingImportCard(
                            job: job,
                            creatorName: viewModel.creatorName(for: job)
                        )
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
                .listRowBackground(LadleTheme.paper)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        _ = viewModel.deleteImport(jobID: job.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
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
                creatorName: viewModel.creatorName(for: job)
            )
        }
        .buttonStyle(.plain)
    }

}
