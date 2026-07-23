import LadleCore
import SwiftUI

struct PendingImportCard: View {
    let job: ImportJob

    var body: some View {
        HStack(spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(LadleTypography.bodyStrong)
                    .foregroundStyle(LadleTheme.ink)
                    .lineLimit(1)

                Text("From \(job.source.libraryTitle) · \(detailText)")
                    .font(LadleTypography.metadata)
                    .foregroundStyle(LadleTheme.ink.opacity(0.56))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            LadlePill(
                text: statusText,
                systemImage: statusSystemImage,
                tint: statusTint,
                foreground: statusForeground
            )
        }
        .padding(14)
        .frame(width: 326)
        .ladleCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(statusText): \(title), from \(job.source.libraryTitle)"
        )
        .accessibilityIdentifier("import.\(job.id.uuidString)")
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
            "Check a few details"
        case .failed:
            "Tap to recover"
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
