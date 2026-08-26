import LadleCore
import SwiftUI

struct PendingImportCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let job: ImportJob
    var creatorName: String?
    var recipeTitle: String?
    var operationFailure: ImportOperationFailure?

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
        .padding(LadleTheme.Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ladleCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(statusText): \(title), from \(job.source.libraryTitle)"
        )
        .accessibilityIdentifier("import.\(job.id.uuidString)")
    }

    private var importDescription: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
            Text(title)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

            Text(byline)
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
        if let systemImage = operationFailure?.report?.failure.systemImage {
            Image(systemName: systemImage)
                .foregroundStyle(LadleTheme.Label.accent)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        } else {
            switch job.status {
            case .parsing:
                ProgressView()
                    .tint(LadleTheme.Label.accent)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            case .needsReview:
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(LadleTheme.Label.accent)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LadleTheme.Label.accent)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LadleTheme.Intent.success)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
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
        if let recipeTitle,
           !recipeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return recipeTitle
        }
        return "\(job.source.libraryTitle) recipe"
    }

    private var statusText: String {
        if let failure = operationFailure?.report?.failure {
            return switch failure {
            case .offline: "Offline"
            case .serviceUnavailable: "Unavailable"
            case .rateLimited: "Try later"
            case .quotaExceeded: "Limit reached"
            case .authenticationExpired: "Sign in again"
            case .invalidResponse, .unknown: "Needs attention"
            }
        }
        return switch job.status {
        case .parsing:
            "Parsing"
        case .needsReview:
            "Check details"
        case .failed:
            "Import failed"
        case .ready:
            "Ready"
        }
    }

    private var byline: String {
        [creatorName, job.source.libraryTitle, detailText]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
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
            operationFailure?.message ?? reason.recoveryMessage
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
            LadleTheme.Surface.steel
        case .failed:
            LadleTheme.Label.accent.opacity(0.11)
        case .ready:
            LadleTheme.Intent.success.opacity(0.12)
        }
    }

    private var statusForeground: Color {
        switch job.status {
        case .failed:
            LadleTheme.Label.accent
        case .ready:
            LadleTheme.Intent.success
        case .parsing, .needsReview:
            LadleTheme.ink
        }
    }
}
