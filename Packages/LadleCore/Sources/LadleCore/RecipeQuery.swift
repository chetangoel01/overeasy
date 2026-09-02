import Foundation

public enum RecipeSort: String, Codable, CaseIterable, Sendable {
    case recentlyAdded
    case cookingTime
    case highestProtein
    case calories
    case alphabetical
}

public struct RecipeQuery: Equatable, Sendable {
    public var searchText: String
    public var sort: RecipeSort
    public var favoritesOnly: Bool
    public var maximumTotalMinutes: Int?
    public var maximumCalories: Decimal?
    public var minimumProtein: Decimal?
    public var maximumCarbohydrates: Decimal?
    public var maximumFat: Decimal?

    public init(
        searchText: String = "",
        sort: RecipeSort = .recentlyAdded,
        favoritesOnly: Bool = false,
        maximumTotalMinutes: Int? = nil,
        maximumCalories: Decimal? = nil,
        minimumProtein: Decimal? = nil,
        maximumCarbohydrates: Decimal? = nil,
        maximumFat: Decimal? = nil
    ) {
        self.searchText = searchText
        self.sort = sort
        self.favoritesOnly = favoritesOnly
        self.maximumTotalMinutes = maximumTotalMinutes
        self.maximumCalories = maximumCalories
        self.minimumProtein = minimumProtein
        self.maximumCarbohydrates = maximumCarbohydrates
        self.maximumFat = maximumFat
    }

    public func apply(to recipes: [Recipe]) -> [Recipe] {
        recipes
            .filter(matches)
            .sorted(by: areInIncreasingOrder)
    }

    private func matches(_ recipe: Recipe) -> Bool {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesSearch = term.isEmpty
            || recipe.title.localizedCaseInsensitiveContains(term)
            || recipe.creatorName?.localizedCaseInsensitiveContains(term) == true
            || recipe.ingredients.contains {
                $0.name.localizedCaseInsensitiveContains(term)
            }

        let matchesFavorite = !favoritesOnly || recipe.isFavorite

        let matchesTime: Bool
        if let maximumTotalMinutes {
            matchesTime = recipe.displayedTime
                .map { $0.minutes <= maximumTotalMinutes } ?? false
        } else {
            matchesTime = true
        }

        let nutrition = perServingNutrition(for: recipe)
        let matchesCalories = maximumCalories.map { maximum in
            nutrition?.calories.map { $0 <= maximum } ?? false
        } ?? true
        let matchesProtein = minimumProtein.map { minimum in
            nutrition?.proteinGrams.map { $0 >= minimum } ?? false
        } ?? true
        let matchesCarbohydrates = maximumCarbohydrates.map { maximum in
            nutrition?.carbohydrateGrams.map { $0 <= maximum } ?? false
        } ?? true
        let matchesFat = maximumFat.map { maximum in
            nutrition?.fatGrams.map { $0 <= maximum } ?? false
        } ?? true

        return matchesSearch
            && matchesFavorite
            && matchesTime
            && matchesCalories
            && matchesProtein
            && matchesCarbohydrates
            && matchesFat
    }

    private func areInIncreasingOrder(_ lhs: Recipe, _ rhs: Recipe) -> Bool {
        switch sort {
        case .recentlyAdded:
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
        case .cookingTime:
            let left = lhs.displayedTime?.minutes ?? .max
            let right = rhs.displayedTime?.minutes ?? .max
            if left != right {
                return left < right
            }
        case .calories:
            let left = perServingNutrition(for: lhs)?.calories
                ?? Decimal.greatestFiniteMagnitude
            let right = perServingNutrition(for: rhs)?.calories
                ?? Decimal.greatestFiniteMagnitude
            if left != right {
                return left < right
            }
        case .highestProtein:
            let left = perServingNutrition(for: lhs)?.proteinGrams
            let right = perServingNutrition(for: rhs)?.proteinGrams
            if left != right {
                switch (left, right) {
                case let (.some(left), .some(right)):
                    return left > right
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    break
                }
            }
        case .alphabetical:
            let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        }

        let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func perServingNutrition(for recipe: Recipe) -> Nutrition? {
        guard let nutrition = recipe.nutrition,
              nutrition.servingBasis > 0 else {
            return nil
        }
        return nutrition.scaled(toServings: 1)
    }
}
