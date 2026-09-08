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
/// Diet comes first, as one row rather than five toggles, because it is no
/// longer chosen here: a cook answers it once during onboarding and changes
/// it in Profile. What this row does is put it down for the evening. The
/// other three families are this session's browsing and sit under labels
/// that say how much of each is on.
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
            // Absent when there is no diet: a row that pauses nothing
            // would only be a second, emptier place to look for a choice
            // that is made in Profile.
            if filters.hasDiet {
                Section("Diet · set in Profile") {
                    Toggle(dietRowTitle, isOn: dietAppliedBinding)
                }
            }

            Menu(
                sectionTitle(
                    "Cuisine",
                    count: filters.browsingFilter.cuisines.count
                )
            ) {
                ForEach(CuisineTag.allCases, id: \.self) { cuisine in
                    Toggle(cuisine.title, isOn: cuisineBinding(cuisine))
                }
            }

            Menu(
                sectionTitle(
                    "Keywords",
                    count: filters.browsingFilter.keywords.count
                )
            ) {
                ForEach(RecipeKeyword.allCases, id: \.self) { keyword in
                    Toggle(keyword.title, isOn: keywordBinding(keyword))
                }
            }

            Menu(
                sectionTitle(
                    "Ingredients",
                    count: filters.browsingFilter.ingredients.count
                )
            ) {
                // Terms are added one at a time and removed the same way:
                // this is an inclusion list, not a search field, and a row
                // that removes itself on tap is the same gesture as the
                // pill. A `Toggle` rather than a button carrying its own
                // glyph, so iOS draws the checkmark column and the row is
                // the same shape as the tag toggles above it.
                ForEach(
                    filters.browsingFilter.ingredients,
                    id: \.self
                ) { term in
                    Toggle(
                        term,
                        isOn: Binding(
                            get: { true },
                            set: { isOn in
                                guard !isOn else { return }
                                filters.browsingFilter.removeIngredient(term)
                            }
                        )
                    )
                }
                if filters.browsingFilter.ingredients.count
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
                filters.browsingFilter.addIngredient(ingredientTerm)
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

    /// The row says which diet and whether it is holding, because a cook
    /// who turned it off an hour ago has to be able to see that from the
    /// menu rather than from a library that looks wrong.
    private var dietRowTitle: String {
        let diet = filters.diets.dietTitle
        return filters.isDietPaused
            ? "\(diet) · Off, showing everything"
            : "\(diet) · On"
    }

    private var dietAppliedBinding: Binding<Bool> {
        Binding(
            get: { !filters.isDietPaused },
            set: { filters.isDietPaused = !$0 }
        )
    }

    private func cuisineBinding(_ cuisine: CuisineTag) -> Binding<Bool> {
        Binding(
            get: { filters.browsingFilter.cuisines.contains(cuisine) },
            set: { isOn in
                if isOn {
                    filters.browsingFilter.cuisines.insert(cuisine)
                } else {
                    filters.browsingFilter.cuisines.remove(cuisine)
                }
            }
        )
    }

    private func keywordBinding(_ keyword: RecipeKeyword) -> Binding<Bool> {
        Binding(
            get: { filters.browsingFilter.keywords.contains(keyword) },
            set: { isOn in
                if isOn {
                    filters.browsingFilter.keywords.insert(keyword)
                } else {
                    filters.browsingFilter.keywords.remove(keyword)
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
            clearFilters: { filters.clearFilters() },
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
                        .accessibilityHint(chip.hint ?? "")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}
