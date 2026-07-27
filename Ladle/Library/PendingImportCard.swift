import LadleCore
import SwiftUI

struct PendingImportCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let job: ImportJob

    var body: some View {
        Group {
            if usesStackedLayout {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        statusIcon
                        importDescription
                    }
                    statusPill
                }
            } else {
                HStack(spacing: 12) {
                    statusIcon
                    importDescription
                    Spacer(minLength: 6)
                    statusPill
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ladleCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(statusText): \(title), from \(job.source.libraryTitle)"
        )
        .accessibilityIdentifier("import.\(job.id.uuidString)")
    }

    private var importDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

            Text("From \(job.source.libraryTitle) · \(detailText)")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.56))
                .lineLimit(usesStackedLayout ? 2 : 1)
                .minimumScaleFactor(
                    usesStackedLayout ? 1 : 0.82
                )
        }
        .layoutPriority(1)
    }

    private var statusPill: some View {
        LadlePill(
            text: statusText,
            systemImage: statusSystemImage,
            tint: statusTint,
            foreground: statusForeground
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .parsing:
            ProgressView()
                .tint(LadleTheme.paprika)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        case .needsReview:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LadleTheme.success)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
    }

    private var usesStackedLayout: Bool {
        if dynamicTypeSize.isAccessibilitySize {
            return true
        }
        switch job.status {
        case .needsReview, .failed:
            return true
        case .parsing, .ready:
            return false
        }
    }

    private var title: String {
        let component = job.sourceURL.lastPathComponent
            .removingPercentEncoding
            ?? job.sourceURL.lastPathComponent
        guard !component.isEmpty else {
            return "Recipe import"
        }
        return component
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .localizedCapitalized
    }

    private var statusText: String {
        switch job.status {
        case .parsing:
            "Parsing"
        case .needsReview:
            "Needs review"
        case .failed:
            "Import failed"
        case .ready:
            "Ready"
        }
    }

    private var detailText: String {
        switch job.status {
        case .parsing:
            "Just added"
        case .needsReview:
            job.candidateRecipeID == nil
                ? "Check a few details"
                : "Open the current recipe"
        case let .failed(reason):
            reason.importInboxMessage
        case .ready:
            "Recipe ready"
        }
    }

    private var statusSystemImage: String {
        switch job.status {
        case .parsing:
            "sparkles"
        case .needsReview:
            "pencil.line"
        case .failed:
            "arrow.clockwise"
        case .ready:
            "checkmark"
        }
    }

    private var statusTint: Color {
        switch job.status {
        case .parsing, .needsReview:
            LadleTheme.review
        case .failed:
            LadleTheme.paprika.opacity(0.11)
        case .ready:
            LadleTheme.success.opacity(0.12)
        }
    }

    private var statusForeground: Color {
        switch job.status {
        case .failed:
            LadleTheme.paprika
        case .ready:
            LadleTheme.success
        case .parsing, .needsReview:
            LadleTheme.ink
        }
    }
}

extension ImportFailure {
    var importInboxMessage: String {
        switch self {
        case .privateOrDeleted:
            "Post is private or unavailable. Add details manually."
        case .unsupportedSource:
            "This source isn’t supported yet."
        case .invalidURL:
            "The saved link is incomplete."
        case .networkUnavailable:
            "Connection interrupted. Open to retry."
        case .authenticationExpired:
            "Sign in again, then retry."
        case .parserUnavailable:
            "Couldn’t read the video. Open for recovery options."
        case .quotaExceeded:
            "Processing limit reached. Try again later."
        }
    }
}
