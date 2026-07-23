import LadleCore
import SwiftUI

struct FilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: LibraryViewModel
    @State private var favoritesOnly: Bool
    @State private var maximumTotalMinutes: Int?
    @State private var maximumCalories: Decimal?

    init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
        _favoritesOnly = State(initialValue: viewModel.favoritesOnly)
        _maximumTotalMinutes = State(
            initialValue: viewModel.maximumTotalMinutes
        )
        _maximumCalories = State(
            initialValue: viewModel.maximumCalories
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    favoritesSection
                    timeSection
                    caloriesSection
                }
                .padding(.horizontal, LadleTheme.Spacing.generous)
                .padding(.vertical, LadleTheme.Spacing.regular)
            }
            .scrollIndicators(.hidden)
            .background(LadleTheme.paper)
            .navigationTitle("Filter Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                applyButton
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("Reset") {
                        favoritesOnly = false
                        maximumTotalMinutes = nil
                        maximumCalories = nil
                    }
                    .foregroundStyle(LadleTheme.paprika)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(LadleTheme.paper)
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(title: "Favorites")

            Button {
                favoritesOnly.toggle()
            } label: {
                HStack {
                    Image(
                        systemName: favoritesOnly
                            ? "heart.fill"
                            : "heart"
                    )
                    Text("Favorites only")
                        .font(LadleTypography.bodyStrong)
                    Spacer()
                    if favoritesOnly {
                        Image(systemName: "checkmark")
                    }
                }
                .foregroundStyle(
                    favoritesOnly
                        ? LadleTheme.paprika
                        : LadleTheme.ink
                )
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(
                    favoritesOnly
                        ? LadleTheme.review
                        : LadleTheme.field,
                    in: RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.control,
                        style: .continuous
                    )
                )
            }
            .accessibilityValue(favoritesOnly ? "Selected" : "Not selected")
        }
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(
                title: "Total time",
                detail: maximumTotalMinutes.map { "Up to \($0) min" }
            )

            HStack(spacing: 8) {
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    FilterChoiceButton(
                        title: "\(minutes) min",
                        accessibilityLabel: "\(minutes) minutes or less",
                        isSelected: maximumTotalMinutes == minutes
                    ) {
                        maximumTotalMinutes = (
                            maximumTotalMinutes == minutes ? nil : minutes
                        )
                    }
                }
            }
        }
    }

    private var caloriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(
                title: "Estimated calories",
                detail: maximumCalories.map {
                    "Up to \(NSDecimalNumber(decimal: $0).stringValue)"
                }
            )

            HStack(spacing: 8) {
                ForEach([400, 600, 800], id: \.self) { calories in
                    FilterChoiceButton(
                        title: "≤ \(calories)",
                        accessibilityLabel: "\(calories) calories or less",
                        isSelected: maximumCalories == Decimal(calories)
                    ) {
                        let value = Decimal(calories)
                        maximumCalories = (
                            maximumCalories == value ? nil : value
                        )
                    }
                }
            }
        }
    }

    private var applyButton: some View {
        Button("Apply Filters") {
            viewModel.favoritesOnly = favoritesOnly
            viewModel.maximumTotalMinutes = maximumTotalMinutes
            viewModel.maximumCalories = maximumCalories
            dismiss()
        }
        .buttonStyle(LadlePrimaryButtonStyle())
        .padding(.horizontal, LadleTheme.Spacing.generous)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

private struct FilterChoiceButton: View {
    let title: String
    let accessibilityLabel: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(LadleTypography.metadata)
                .foregroundStyle(
                    isSelected ? Color.white : LadleTheme.ink
                )
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    isSelected ? LadleTheme.paprika : LadleTheme.field,
                    in: RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.control,
                        style: .continuous
                    )
                )
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}
