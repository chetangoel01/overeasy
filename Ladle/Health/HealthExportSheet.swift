import Foundation
import LadleCore
import SwiftUI

struct HealthExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.ladleAccent) private var accent

    @State private var viewModel: HealthExportViewModel

    init(
        recipeTitle: String,
        nutrition: Nutrition,
        service: any HealthService
    ) {
        _viewModel = State(
            initialValue: HealthExportViewModel(
                recipeTitle: recipeTitle,
                nutrition: nutrition,
                service: service
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case let .succeeded(receipt):
                    successContent(receipt)
                case .denied:
                    deniedContent
                case let .failed(failure):
                    failedContent(failure)
                case .idle, .exporting:
                    confirmationContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LadleTheme.Surface.porcelain)
            .accessibilityIdentifier("health.export")
            .navigationTitle("Apple Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .padding(
                        .leading,
                        LadleTheme.Layout.sheetToolbarInset
                    )
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LadleTheme.Surface.porcelain)
    }

    private var confirmationContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LadleTheme.Layout.sectionGap) {
                header
                servingPicker
                exportPreview
                permissionNote

                Button {
                    Task {
                        await viewModel.confirmExport()
                    }
                } label: {
                    if viewModel.state == .exporting {
                        ProgressView()
                            .tint(LadleTheme.Label.onAccent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Confirm & Export")
                    }
                }
                .buttonStyle(LadleButtonStyle(role: .primary))
                .disabled(viewModel.state == .exporting)
            }
            .padding(LadleTheme.Spacing.generous)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
            Image(systemName: "heart.text.clipboard")
                .font(.system(size: LadleTheme.IconSize.large, weight: .semibold))
                .foregroundStyle(accent.label)
                .frame(width: 52, height: 52)
                .background(LadleTheme.Surface.badge, in: Circle())

            Text("Add nutrition to Apple Health")
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.Label.primary)

            Text(
                "Choose how much you ate, review the values, then confirm the export."
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.Label.primary.opacity(0.64))
        }
    }

    private var servingPicker: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Servings eaten")
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.primary.opacity(0.58))
                Text(servingText)
                    .ladleFont(.recipeTitle)
                    .foregroundStyle(LadleTheme.Label.primary)
            }

            Spacer()

            Stepper(
                "",
                value: $viewModel.selectedServings,
                in: 0.5...8,
                step: 0.5
            )
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Servings to export")
            .accessibilityValue(servingText)
        }
        .padding(16)
        .background(
            LadleTheme.Surface.raised,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    private var exportPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(
                title: "What will be written",
                detail: "\(viewModel.payload.metrics.count) values"
            )

            VStack(spacing: 0) {
                ForEach(
                    Array(viewModel.payload.metrics.enumerated()),
                    id: \.element.id
                ) { index, metric in
                    HStack {
                        Text(metric.kind.displayName)
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.Label.primary)
                        Spacer()
                        Text(metricText(metric))
                            .ladleFont(.bodyStrong)
                            .foregroundStyle(LadleTheme.Label.primary)
                    }
                    .padding(.vertical, 12)

                    if index < viewModel.payload.metrics.count - 1 {
                        Divider()
                            .overlay(LadleTheme.Label.primary.opacity(0.08))
                    }
                }
            }
            .padding(.horizontal, LadleTheme.Layout.cardPadding)
            .ladleCard()
        }
    }

    private var permissionNote: some View {
        Label(
            "Apple will ask for permission only after you confirm. Overeasy never exports nutrition automatically.",
            systemImage: "lock.shield"
        )
        .ladleFont(.metadata)
        .foregroundStyle(LadleTheme.Label.primary.opacity(0.64))
        .padding(LadleTheme.Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LadleTheme.Surface.steel,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    private func successContent(
        _ receipt: HealthExportReceipt
    ) -> some View {
        resultContent(
            icon: "checkmark",
            title: "Added to Apple Health",
            message:
                "\(receipt.exportedMetrics.count) nutrition values were added for \(servingText(for: receipt.payload.servings)).",
            primaryTitle: "Done",
            primaryAction: {
                dismiss()
            }
        )
    }

    private var deniedContent: some View {
        resultContent(
            icon: "heart.slash",
            title: "Nothing was exported",
            message:
                "Apple Health permission wasn’t granted. Your recipe is unchanged and you can try again anytime.",
            primaryTitle: "Try Again",
            primaryAction: viewModel.resetResult
        )
    }

    private func failedContent(_ failure: HealthExportFailure) -> some View {
        switch failure {
        case .noNutrition:
            resultContent(
                icon: "chart.bar.doc.horizontal",
                title: "No nutrition to export",
                message:
                    "This recipe doesn’t contain nutrition values, so nothing can be added to Apple Health.",
                primaryTitle: nil,
                primaryAction: {}
            )
        case let .remote(report):
            resultContent(
                icon: report.failure.systemImage,
                title: report.failure == .offline
                    ? "You’re offline"
                    : "Export didn’t finish",
                message: report.failure == .offline
                    ? "Nothing was written to Apple Health. Reconnect and try again."
                    : "Nothing was written to Apple Health. Check your settings and try again.",
                primaryTitle: failure.canRetry ? "Try Again" : nil,
                primaryAction: viewModel.resetResult
            )
        }
    }

    private func resultContent(
        icon: String,
        title: String,
        message: String,
        primaryTitle: String?,
        primaryAction: @escaping () -> Void
    ) -> some View {
        VStack(spacing: LadleTheme.Spacing.regular) {
            Image(systemName: icon)
                .font(.system(size: LadleTheme.IconSize.feature, weight: .bold))
                .foregroundStyle(LadleTheme.Label.onAccent)
                .frame(width: 62, height: 62)
                .background(accent.intent, in: Circle())

            Text(title)
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.Label.primary)
                .multilineTextAlignment(.center)

            Text(message)
                .ladleFont(.body)
                .foregroundStyle(LadleTheme.Label.primary.opacity(0.64))
                .multilineTextAlignment(.center)

            if let primaryTitle {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(LadleButtonStyle(role: .primary))
            }

            Button("Close") {
                dismiss()
            }
            .buttonStyle(LadleButtonStyle(role: .tertiary))
        }
        .padding(LadleTheme.Spacing.generous)
    }

    private var servingText: String {
        servingText(for: viewModel.payload.servings)
    }

    private func servingText(for servings: Decimal) -> String {
        let value = decimalText(servings)
        return servings == 1 ? "1 serving" : "\(value) servings"
    }

    private func metricText(_ metric: HealthExportMetric) -> String {
        let prefix = (
            metric.kind == .calories && viewModel.payload.isEstimated
        ) ? "≈ " : ""
        return "\(prefix)\(decimalText(metric.amount)) \(metric.kind.unitSymbol)"
    }

    private func decimalText(_ value: Decimal) -> String {
        ladleNumber(value)
    }
}
