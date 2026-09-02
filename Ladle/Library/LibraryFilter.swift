import Foundation

/// What the Recipes filter menu offers, and the words for every value.
///
/// The menu rows and the active-filter pills both read these titles, so a
/// value can never be named one thing on the checked row and another on the
/// pill that removes it — which is exactly how the old sheet drifted from the
/// header around it.
enum LibraryFilter: CaseIterable {
    case time
    case calories
    case protein
    case carbohydrates
    case fat

    static let anyTitle = "Any"

    var title: String {
        switch self {
        case .time: "Time"
        case .calories: "Calories"
        case .protein: "Protein"
        case .carbohydrates: "Carbohydrates"
        case .fat: "Fat"
        }
    }

    /// Every option is a whole number, which is what lets the four `Decimal`
    /// filters share this list with the `Int` one.
    var options: [Int] {
        switch self {
        case .time: [15, 30, 45, 60]
        case .calories: [400, 600, 800]
        case .protein: [20, 30, 40]
        case .carbohydrates: [30, 50]
        case .fat: [15, 25]
        }
    }

    func optionTitle(_ value: Int) -> String {
        switch self {
        case .time: "\(value) min or less"
        case .calories: "\(value) or fewer"
        case .protein: "\(value) g or more"
        case .carbohydrates, .fat: "Under \(value) g"
        }
    }

    /// A submenu's own label carries its current value, so the filter state
    /// reads without opening five submenus to find it.
    func menuTitle(for value: Int?) -> String {
        "\(title) · \(value.map(optionTitle) ?? Self.anyTitle)"
    }
}

/// One active filter, as the pills row under the header shows it: the words
/// for the value, and the way to take it off again.
struct LibraryFilterChip: Identifiable {
    let title: String
    let remove: () -> Void

    var id: String { title }

    /// Built here rather than in the view so the menu's wording and the
    /// pills' wording are testable as the one thing they are.
    @MainActor
    static func chips(for viewModel: LibraryViewModel) -> [LibraryFilterChip] {
        var chips: [LibraryFilterChip] = []
        if viewModel.selectedCollection != .all {
            chips.append(
                LibraryFilterChip(
                    title: viewModel.selectedCollection.title,
                    remove: { viewModel.selectedCollection = .all }
                )
            )
        }
        if viewModel.favoritesOnly {
            chips.append(
                LibraryFilterChip(
                    title: "Favorites",
                    remove: viewModel.removeFavoritesFilter
                )
            )
        }
        for (filter, value, remove) in numericFilters(of: viewModel) {
            guard let value else { continue }
            chips.append(
                LibraryFilterChip(
                    title: filter.optionTitle(value),
                    remove: remove
                )
            )
        }
        return chips
    }

    @MainActor
    private static func numericFilters(
        of viewModel: LibraryViewModel
    ) -> [(LibraryFilter, Int?, () -> Void)] {
        [
            (
                .time,
                viewModel.maximumTotalMinutes,
                viewModel.removeMaximumTimeFilter
            ),
            (
                .calories,
                viewModel.maximumCalories.map(LibraryFilter.option),
                viewModel.removeMaximumCaloriesFilter
            ),
            (
                .protein,
                viewModel.minimumProtein.map(LibraryFilter.option),
                viewModel.removeMinimumProteinFilter
            ),
            (
                .carbohydrates,
                viewModel.maximumCarbohydrates.map(LibraryFilter.option),
                viewModel.removeMaximumCarbohydratesFilter
            ),
            (
                .fat,
                viewModel.maximumFat.map(LibraryFilter.option),
                viewModel.removeMaximumFatFilter
            ),
        ]
    }
}

extension LibraryFilter {
    /// The whole-number option a `Decimal` filter holds. The four decimal
    /// filters are only ever written from `options`, so the round trip back
    /// to `Int` is exact.
    static func option(_ value: Decimal) -> Int {
        NSDecimalNumber(decimal: value).intValue
    }
}
