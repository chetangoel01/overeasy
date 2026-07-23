import Foundation

public enum RecipeSort: String, Codable, CaseIterable, Sendable {
    case recentlyAdded
    case cookingTime
    case calories
    case alphabetical
}

public struct RecipeQuery: Equatable, Sendable {
    public var searchText: String
    public var sort: RecipeSort
    public var favoritesOnly: Bool
    public var maximumTotalMinutes: Int?
    public var maximumCalories: Decimal?

    public init(
        searchText: String = "",
        sort: RecipeSort = .recentlyAdded,
        favoritesOnly: Bool = false,
        maximumTotalMinutes: Int? = nil,
        maximumCalories: Decimal? = nil
    ) {
        self.searchText = searchText
        self.sort = sort
        self.favoritesOnly = favoritesOnly
        self.maximumTotalMinutes = maximumTotalMinutes
        self.maximumCalories = maximumCalories
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

        let matchesFavorite = !favoritesOnly || recipe.isFavorite

        let matchesTime: Bool
        if let maximumTotalMinutes {
            matchesTime = recipe.totalMinutes.map { $0 <= maximumTotalMinutes } ?? false
        } else {
            matchesTime = true
        }

        let matchesCalories: Bool
        if let maximumCalories {
            matchesCalories = recipe.nutrition?.calories
                .map { $0 <= maximumCalories } ?? false
        } else {
            matchesCalories = true
        }

        return matchesSearch
            && matchesFavorite
            && matchesTime
            && matchesCalories
    }

    private func areInIncreasingOrder(_ lhs: Recipe, _ rhs: Recipe) -> Bool {
        switch sort {
        case .recentlyAdded:
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
        case .cookingTime:
            let left = lhs.totalMinutes ?? .max
            let right = rhs.totalMinutes ?? .max
            if left != right {
                return left < right
            }
        case .calories:
            let left = lhs.nutrition?.calories ?? Decimal.greatestFiniteMagnitude
            let right = rhs.nutrition?.calories ?? Decimal.greatestFiniteMagnitude
            if left != right {
                return left < right
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
}
