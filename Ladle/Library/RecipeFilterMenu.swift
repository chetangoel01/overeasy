import LadleCore
import SwiftUI

/// The filter control, once, for all three tabs.
///
/// It is the Recipes menu from #63 rebuilt on the shared model rather than a
/// second control beside it: inline pickers and toggles that write the state
/// directly, so a tap applies at once and there is no Apply to forget. Each
/// submenu's label carries its own current value, which is what lets the
/// whole filter read without opening anything.
///
/// Diet comes first and is not behind a submenu. It is the only family that
/// survives the launch, so it is the one a cook needs to see the state of
/// without hunting; the other three are this session's browsing and sit
/// under labels that say how much of each is on.
struct RecipeFilterMenu<Label: View, Extra: View>: View {
    @Bindable var filters: RecipeFilterStore
    /// Rows that belong to one tab only — the library's favorites, time and
    /// nutrition dimensions, which no server-side feed can answer.
    @ViewBuilder var extraSections: () -> Extra
    /// Whether anything at all is on, including the caller's own rows.
    let hasActiveFilters: Bool
    let clearFilters: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var ingredientTerm = ""
    @State private var isAddingIngredient = false

    var body: some View {
        Menu {
            Section("Diet") {
                ForEach(DietTag.allCases, id: \.self) { diet in
                    Toggle(diet.title, isOn: dietBinding(diet))
                }
            }

            Menu(
                sectionTitle("Cuisine", count: filters.filter.cuisines.count)
            ) {
                ForEach(CuisineTag.allCases, id: \.self) { cuisine in
                    Toggle(cuisine.title, isOn: cuisineBinding(cuisine))
                }
            }

            Menu(
                sectionTitle("Keywords", count: filters.filter.keywords.count)
            ) {
                ForEach(RecipeKeyword.allCases, id: \.self) { keyword in
                    Toggle(keyword.title, isOn: keywordBinding(keyword))
                }
            }

            Menu(
                sectionTitle(
                    "Ingredients",
                    count: filters.filter.ingredients.count
                )
            ) {
                // Terms are added one at a time and removed the same way:
                // this is an inclusion list, not a search field, and a row
                // that removes itself on tap is the same gesture as the
                // pill. A `Toggle` rather than a button carrying its own
                // glyph, so iOS draws the checkmark column and the row is
                // the same shape as the tag toggles above it.
                ForEach(filters.filter.ingredients, id: \.self) { term in
                    Toggle(
                        term,
                        isOn: Binding(
                            get: { true },
                            set: { isOn in
                                guard !isOn else { return }
                                filters.filter.removeIngredient(term)
                            }
                        )
                    )
                }
                if filters.filter.ingredients.count
                    < RecipeFilter.maximumIngredientTerms {
                    Button("Add ingredient…") {
                        ingredientTerm = ""
                        isAddingIngredient = true
                    }
                }
            }

            extraSections()

            // Its own trailing section, and absent rather than disabled: a
            // menu draws a disabled destructive row badly, and keeping it at
            // the end means nothing above it moves when it appears.
            if hasActiveFilters {
                Divider()
                Button("Clear filters", role: .destructive, action: clearFilters)
            }
        } label: {
            label()
        }
        .menuOrder(.fixed)
        .accessibilityLabel(buttonTitle)
        .alert("Add ingredient", isPresented: $isAddingIngredient) {
            TextField("Ingredient", text: $ingredientTerm)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                filters.filter.addIngredient(ingredientTerm)
                ingredientTerm = ""
            }
        } message: {
            Text("Only recipes that list this ingredient will be shown.")
        }
    }

    /// The label a filter button carries: the count is the whole state in a
    /// word, and VoiceOver reads it without opening the menu.
    private var buttonTitle: String {
        let count = filters.filter.activeCount
        return count == 0 ? "Filters" : "Filters \(count)"
    }

    private func sectionTitle(_ name: String, count: Int) -> String {
        count == 0 ? "\(name) · Any" : "\(name) · \(count)"
    }

    private func dietBinding(_ diet: DietTag) -> Binding<Bool> {
        Binding(
            get: { filters.filter.diets.contains(diet) },
            set: { isOn in
                if isOn {
                    filters.filter.diets.insert(diet)
                } else {
                    filters.filter.diets.remove(diet)
                }
            }
        )
    }

    private func cuisineBinding(_ cuisine: CuisineTag) -> Binding<Bool> {
        Binding(
            get: { filters.filter.cuisines.contains(cuisine) },
            set: { isOn in
                if isOn {
                    filters.filter.cuisines.insert(cuisine)
                } else {
                    filters.filter.cuisines.remove(cuisine)
                }
            }
        )
    }

    private func keywordBinding(_ keyword: RecipeKeyword) -> Binding<Bool> {
        Binding(
            get: { filters.filter.keywords.contains(keyword) },
            set: { isOn in
                if isOn {
                    filters.filter.keywords.insert(keyword)
                } else {
                    filters.filter.keywords.remove(keyword)
                }
            }
        )
    }
}

extension RecipeFilterMenu where Extra == EmptyView {
    /// Discover and Watch have no dimensions of their own: everything they
    /// can filter on, the server answers.
    init(
        filters: RecipeFilterStore,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.init(
            filters: filters,
            extraSections: { EmptyView() },
            hasActiveFilters: !filters.filter.isEmpty,
            clearFilters: { filters.filter.clear() },
            label: label
        )
    }
}

/// The pills under a header: what is on, and the way to take it off. Shared
/// so the three tabs cannot word the same filter differently.
struct RecipeFilterChipsRow: View {
    let chips: [LibraryFilterChip]

    var body: some View {
        if !chips.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(chips) { chip in
                        Button(action: chip.remove) {
                            LadlePill(
                                text: chip.title,
                                systemImage: "xmark",
                                tint: LadleTheme.Intent.success.opacity(0.45)
                            )
                        }
                        .buttonStyle(LadlePressButtonStyle())
                        .accessibilityLabel("Remove filter: \(chip.title)")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}
