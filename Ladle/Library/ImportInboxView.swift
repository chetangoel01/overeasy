import LadleCore
import SwiftUI

struct ImportInboxView: View {
    @Bindable var viewModel: LibraryViewModel
    let recoverImport: (ImportJob) -> Void
    let openReview: (Recipe, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            LibraryDestinationHeader(
                "Import inbox",
                detail: inboxDetail
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    jobs
                    howItWorks
                }
                .padding(.horizontal, LadleTheme.Spacing.regular)
                .padding(.bottom, 44)
            }
            .scrollIndicators(.hidden)
        }
        .background(LadleTheme.paper)
        .toolbar(.hidden, for: .navigationBar)
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
        } else {
            VStack(alignment: .leading, spacing: 12) {
                LadleSectionHeader(
                    title: "In progress",
                    detail: inboxDetail
                )
                ForEach(viewModel.actionableImportJobs) { job in
                    if case .failed = job.status {
                        Button {
                            recoverImport(job)
                        } label: {
                            PendingImportCard(job: job)
                        }
                        .buttonStyle(.plain)
                    } else if let recipe = viewModel.recipeForReview(job) {
                        Button {
                            openReview(
                                recipe,
                                job.candidateRecipeID == nil
                                    ? "Needs review"
                                    : "Current recipe · re-import review pending"
                            )
                        } label: {
                            PendingImportCard(job: job)
                        }
                        .buttonStyle(.plain)
                    } else {
                        PendingImportCard(job: job)
                    }
                }
            }
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 0) {
            LadleSectionHeader(
                title: "How imports work",
                detail: "Your source link stays safe"
            )
            .padding(.bottom, 6)
            explanation(
                "Parsing",
                detail: "Ladle reads the source and structures the recipe.",
                icon: "sparkles"
            )
            explanation(
                "Needs review",
                detail: "Check uncertain details before cooking.",
                icon: "pencil.line"
            )
            explanation(
                "Failed",
                detail: "Retry, add context, paste details, or create manually.",
                icon: "arrow.clockwise"
            )
        }
    }

    private func explanation(
        _ title: String,
        detail: String,
        icon: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                Text(detail)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.mutedInk)
            }
        }
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) {
            Divider().overlay(LadleTheme.ink.opacity(0.08))
        }
    }

    private var inboxDetail: String {
        let count = viewModel.actionableImportJobs.count
        return count == 1 ? "1 active import" : "\(count) active imports"
    }
}
