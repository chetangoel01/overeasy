import SwiftUI

struct FilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    let viewModel: LibraryViewModel
    @State private var favoritesOnly: Bool
    @State private var maximumTotalMinutes: Int?
    @State private var maximumCalories: Decimal?
    @State private var minimumProtein: Decimal?
    @State private var maximumCarbohydrates: Decimal?
    @State private var maximumFat: Decimal?

    init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
        _favoritesOnly = State(initialValue: viewModel.favoritesOnly)
        _maximumTotalMinutes = State(initialValue: viewModel.maximumTotalMinutes)
        _maximumCalories = State(initialValue: viewModel.maximumCalories)
        _minimumProtein = State(initialValue: viewModel.minimumProtein)
        _maximumCarbohydrates = State(
            initialValue: viewModel.maximumCarbohydrates
        )
        _maximumFat = State(initialValue: viewModel.maximumFat)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    favoritesSection
                    timeSection
                    DecimalFilterSection(
                        title: "Calories",
                        detail: "Maximum per serving",
                        options: [400, 600, 800],
                        selection: $maximumCalories,
                        titleForOption: { "\($0)" },
                        accessibilityLabel: { "\($0) calories or less" }
                    )
                    DecimalFilterSection(
                        title: "Protein",
                        detail: "Minimum per serving",
                        options: [20, 30, 40],
                        selection: $minimumProtein,
                        titleForOption: { "\($0) g+" },
                        accessibilityLabel: { "\($0) grams protein or more" }
                    )
                    DecimalFilterSection(
                        title: "Carbohydrates",
                        detail: "Maximum per serving",
                        options: [30, 50],
                        selection: $maximumCarbohydrates,
                        titleForOption: { "Under \($0) g" },
                        accessibilityLabel: {
                            "Under \($0) grams carbohydrates"
                        }
                    )
                    DecimalFilterSection(
                        title: "Fat",
                        detail: "Maximum per serving",
                        options: [15, 25],
                        selection: $maximumFat,
                        titleForOption: { "Under \($0) g" },
                        accessibilityLabel: { "Under \($0) grams fat" }
                    )
                }
                .padding(.horizontal, LadleTheme.Spacing.generous)
                .padding(.vertical, LadleTheme.Spacing.regular)
            }
            .scrollIndicators(.hidden)
            .background(LadleTheme.paper)
            .navigationTitle("Filter recipes")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button("Apply Filters", action: apply)
                    .buttonStyle(LadleButtonStyle(role: .primary))
                    .padding(.horizontal, LadleTheme.Spacing.generous)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset", action: reset)
                        .foregroundStyle(LadleTheme.Label.accent)
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LadleTheme.paper)
    }

    private var favoritesSection: some View {
        Toggle("Favorites only", isOn: $favoritesOnly)
            .ladleFont(.bodyStrong)
            .foregroundStyle(LadleTheme.ink)
            .tint(LadleTheme.plum)
            .padding(.horizontal, LadleTheme.Layout.cardPadding)
            .frame(minHeight: 52)
            .background(
                LadleTheme.Surface.raised,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
    }

    private var timeSection: some View {
        FilterSection(title: "Total time", detail: "Maximum") {
            FilterChoices(
                options: [15, 30, 45, 60],
                selection: $maximumTotalMinutes,
                title: { "\($0) min" },
                accessibilityLabel: { "\($0) minutes or less" }
            )
        }
    }

    private func apply() {
        viewModel.favoritesOnly = favoritesOnly
        viewModel.maximumTotalMinutes = maximumTotalMinutes
        viewModel.maximumCalories = maximumCalories
        viewModel.minimumProtein = minimumProtein
        viewModel.maximumCarbohydrates = maximumCarbohydrates
        viewModel.maximumFat = maximumFat
        dismiss()
    }

    private func reset() {
        favoritesOnly = false
        maximumTotalMinutes = nil
        maximumCalories = nil
        minimumProtein = nil
        maximumCarbohydrates = nil
        maximumFat = nil
    }
}

private struct DecimalFilterSection: View {
    let title: String
    let detail: String
    let options: [Int]
    @Binding var selection: Decimal?
    let titleForOption: (Int) -> String
    let accessibilityLabel: (Int) -> String

    var body: some View {
        FilterSection(title: title, detail: detail) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 82), spacing: 8)],
                spacing: 8
            ) {
                FilterChoiceButton(
                    title: "Any",
                    accessibilityLabel: "Any \(title.lowercased())",
                    isSelected: selection == nil
                ) {
                    selection = nil
                }
                ForEach(options, id: \.self) { option in
                    let value = Decimal(option)
                    FilterChoiceButton(
                        title: titleForOption(option),
                        accessibilityLabel: accessibilityLabel(option),
                        isSelected: selection == value
                    ) {
                        selection = selection == value ? nil : value
                    }
                }
            }
        }
    }
}

private struct FilterSection<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Layout.rowGap) {
            LadleSectionHeader(title: title, detail: detail)
            content
        }
    }
}

private struct FilterChoices: View {
    let options: [Int]
    @Binding var selection: Int?
    let title: (Int) -> String
    let accessibilityLabel: (Int) -> String

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 72), spacing: 8)],
            spacing: 8
        ) {
            FilterChoiceButton(
                title: "Any",
                accessibilityLabel: "Any total time",
                isSelected: selection == nil
            ) {
                selection = nil
            }
            ForEach(options, id: \.self) { option in
                FilterChoiceButton(
                    title: title(option),
                    accessibilityLabel: accessibilityLabel(option),
                    isSelected: selection == option
                ) {
                    selection = selection == option ? nil : option
                }
            }
        }
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
                .ladleFont(.metadata)
                .foregroundStyle(
                    isSelected ? LadleTheme.onAccent : LadleTheme.ink
                )
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(
                    isSelected ? LadleTheme.plum : LadleTheme.Surface.raised,
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
