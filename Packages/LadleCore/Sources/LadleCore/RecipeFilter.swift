import Foundation

/// What a cook is looking for, in the one shape Recipes, Discover and Watch
/// all read.
///
/// The three tabs answer it differently — the library filters its own
/// decoded recipes here, Discover and Watch hand the same values to the
/// server as query parameters — but the *state* is one value, so a diet
/// chosen on one tab is already true on the next. The families combine the
/// way the backend combines them, and this type is where that rule is
/// written down for the client: every diet must hold, any cuisine, any
/// keyword, and every ingredient term must appear.
public struct RecipeFilter: Equatable, Sendable {
    /// The server accepts at most ten terms of a hundred characters. They
    /// are enforced here rather than at the request, so a cook is stopped by
    /// a full list instead of by a 422 that reads as an empty app.
    public static let maximumIngredientTerms = 10
    public static let maximumIngredientTermLength = 100

    public var diets: Set<DietTag>
    public var cuisines: Set<CuisineTag>
    public var keywords: Set<RecipeKeyword>
    /// Substrings matched against ingredient names, lower-cased on the way
    /// in so "Chicken" and "chicken" are the one term.
    public private(set) var ingredients: [String]

    public init(
        diets: Set<DietTag> = [],
        cuisines: Set<CuisineTag> = [],
        keywords: Set<RecipeKeyword> = [],
        ingredients: [String] = []
    ) {
        self.diets = diets
        self.cuisines = cuisines
        self.keywords = keywords
        self.ingredients = []
        ingredients.forEach { _ = addIngredient($0) }
    }

    public static let none = RecipeFilter()

    /// Diet is asked about on its own everywhere: it is the one family that
    /// outlives the session, so it is the one family a screen has to be able
    /// to point at without counting the others.
    public var hasDiet: Bool { !diets.isEmpty }

    public var isEmpty: Bool {
        diets.isEmpty
            && cuisines.isEmpty
            && keywords.isEmpty
            && ingredients.isEmpty
    }

    public var orderedDiets: [DietTag] { DietTag.ordered(diets) }
    public var orderedCuisines: [CuisineTag] { CuisineTag.ordered(cuisines) }
    public var orderedKeywords: [RecipeKeyword] {
        RecipeKeyword.ordered(keywords)
    }

    /// Adds a typed term, and reports whether it was taken. False means the
    /// list was full or the term was blank or already there — all three of
    /// which the field says out loud rather than swallowing.
    @discardableResult
    public mutating func addIngredient(_ term: String) -> Bool {
        let normalized = String(
            term
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .prefix(Self.maximumIngredientTermLength)
        )
        guard !normalized.isEmpty,
              !ingredients.contains(normalized),
              ingredients.count < Self.maximumIngredientTerms
        else { return false }
        ingredients.append(normalized)
        return true
    }

    public mutating func removeIngredient(_ term: String) {
        ingredients.removeAll { $0 == term }
    }

    /// Everything except the diet, which is who the cook is rather than what
    /// they are browsing for and so survives a Clear the way it survives a
    /// launch.
    public mutating func clearBrowsingFilters() {
        cuisines = []
        keywords = []
        ingredients = []
    }

    public mutating func clear() {
        diets = []
        clearBrowsingFilters()
    }

    /// The library's own answer. Recipes never asks the server to filter —
    /// the tags travelled with the recipe, so the work is already local, and
    /// a network round trip to narrow a list the cook is holding would be a
    /// spinner over their own library.
    public func apply(to recipes: [Recipe]) -> [Recipe] {
        isEmpty ? recipes : recipes.filter(matches)
    }

    public func matches(_ recipe: Recipe) -> Bool {
        guard diets.isSubset(of: Set(recipe.diets)) else { return false }
        if !cuisines.isEmpty, cuisines.isDisjoint(with: Set(recipe.cuisines)) {
            return false
        }
        if !keywords.isEmpty, keywords.isDisjoint(with: Set(recipe.keywords)) {
            return false
        }
        return ingredients.allSatisfy { term in
            recipe.ingredients.contains {
                $0.name.lowercased().contains(term)
            }
        }
    }
}
