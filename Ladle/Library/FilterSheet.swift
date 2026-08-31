import SwiftUI

/// Filters as a standard grouped form rather than hand-drawn chip grids.
/// Every row is a system control, so spacing, grouping, selection and Dynamic
/// Type come from iOS instead of being re-derived here — which is what made
/// the old sheet read as arbitrary.
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
            Form {
                Section {
                    Toggle("Favorites only", isOn: $favoritesOnly)
                }

                Section("Time") {
                    Picker("Total time", selection: $maximumTotalMinutes) {
                        Text("Any").tag(Int?.none)
                        ForEach([15, 30, 45, 60], id: \.self) { minutes in
                            Text("\(minutes) min or less")
                                .tag(Int?.some(minutes))
                        }
                    }
                }

                Section {
                    decimalPicker(
                        "Calories",
                        selection: $maximumCalories,
                        options: [400, 600, 800],
                        label: { "\($0) or fewer" }
                    )
                    decimalPicker(
                        "Protein",
                        selection: $minimumProtein,
                        options: [20, 30, 40],
                        label: { "\($0) g or more" }
                    )
                    decimalPicker(
                        "Carbohydrates",
                        selection: $maximumCarbohydrates,
                        options: [30, 50],
                        label: { "Under \($0) g" }
                    )
                    decimalPicker(
                        "Fat",
                        selection: $maximumFat,
                        options: [15, 25],
                        label: { "Under \($0) g" }
                    )
                } header: {
                    Text("Nutrition")
                } footer: {
                    Text("Measured per serving.")
                }

                Section {
                    Button("Reset filters", role: .destructive, action: reset)
                        .disabled(!hasActiveFilters)
                }
            }
            .navigationTitle("Filter recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: apply)
                }
            }
        }
        .presentationDetents([.large])
    }

    /// The nutrition filters differ only in their options and phrasing, so
    /// they share one row builder rather than four near-identical blocks.
    private func decimalPicker(
        _ title: String,
        selection: Binding<Decimal?>,
        options: [Int],
        label: @escaping (Int) -> String
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Any").tag(Decimal?.none)
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(Decimal?.some(Decimal(option)))
            }
        }
    }

    private var hasActiveFilters: Bool {
        favoritesOnly
            || maximumTotalMinutes != nil
            || maximumCalories != nil
            || minimumProtein != nil
            || maximumCarbohydrates != nil
            || maximumFat != nil
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
