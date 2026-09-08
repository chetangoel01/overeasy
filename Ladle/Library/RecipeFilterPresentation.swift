import LadleCore

/// The words for every tag, and the pills that say which of them are on.
///
/// `LadleCore` carries the vocabularies without any presentation, the way
/// `RecipeSort` does, so the one place a tag is written for a human is here
/// — a menu row and its pill cannot name the same value differently.
extension DietTag {
    var title: String {
        switch self {
        case .vegetarian: "Vegetarian"
        case .vegan: "Vegan"
        case .pescatarian: "Pescatarian"
        case .glutenFree: "Gluten-free"
        case .dairyFree: "Dairy-free"
        }
    }
}

/// The whole diet as one phrase — "Vegetarian diet", "Vegetarian and
/// gluten-free diet". A diet stands alone under a header and outlives the
/// session, so it says what kind of thing it is rather than leaving "Vegan"
/// to be read as a cuisine; and it is one thing rather than a list, because
/// the cook set it once and pauses it all at once.
extension Set<DietTag> {
    var dietTitle: String {
        DietTag.ordered(self)
            .map(\.title)
            .formatted(.list(type: .and)) + " diet"
    }
}

extension CuisineTag {
    var title: String {
        switch self {
        case .american: "American"
        case .british: "British"
        case .caribbean: "Caribbean"
        case .chinese: "Chinese"
        case .french: "French"
        case .indian: "Indian"
        case .italian: "Italian"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .latinAmerican: "Latin American"
        case .mediterranean: "Mediterranean"
        case .mexican: "Mexican"
        case .middleEastern: "Middle Eastern"
        case .southeastAsian: "Southeast Asian"
        case .westAfrican: "West African"
        }
    }
}

extension RecipeKeyword {
    var title: String {
        switch self {
        case .onePot: "One pot"
        case .weeknight: "Weeknight"
        case .mealPrep: "Meal prep"
        case .highProtein: "High protein"
        case .budget: "Budget"
        case .comfortFood: "Comfort food"
        case .airFryer: "Air fryer"
        case .slowCooker: "Slow cooker"
        case .pressureCooker: "Pressure cooker"
        case .sheetPan: "Sheet pan"
        case .noCook: "No cook"
        case .baking: "Baking"
        case .grilling: "Grilling"
        case .freezerFriendly: "Freezer friendly"
        case .kidFriendly: "Kid friendly"
        case .partyFood: "Party food"
        case .breakfast: "Breakfast"
        case .brunch: "Brunch"
        case .lunchbox: "Lunchbox"
        case .dessert: "Dessert"
        case .snack: "Snack"
        case .sideDish: "Side dish"
        case .soup: "Soup"
        case .salad: "Salad"
        case .pasta: "Pasta"
        }
    }
}

extension RecipeFilter {
    /// One line naming what is on, for an empty state to point at. Written
    /// as a sentence fragment so a screen can say "No recipes match
    /// <this>." without a second phrasing per tab.
    var summary: String {
        var parts: [String] = []
        if !diets.isEmpty {
            parts.append(diets.dietTitle)
        }
        if !cuisines.isEmpty {
            parts.append(
                orderedCuisines.map(\.title).formatted(.list(type: .or))
            )
        }
        if !keywords.isEmpty {
            parts.append(
                orderedKeywords.map(\.title).formatted(.list(type: .or))
            )
        }
        if !ingredients.isEmpty {
            parts.append(ingredients.formatted(.list(type: .and)))
        }
        return parts.formatted(.list(type: .and))
    }

    /// How many pills the filter is worth. The control's label carries it,
    /// so the state reads without opening the menu.
    var activeCount: Int {
        diets.count + cuisines.count + keywords.count + ingredients.count
    }
}

extension LibraryFilterChip {
    /// The shared tag filter as pills, in vocabulary order and with the diet
    /// first — the same order the menu lists them in, so taking one off is
    /// the reverse of putting it on.
    ///
    /// The diet is one pill however many diets it holds, and its ✕ *pauses*
    /// it rather than deleting it: the diet is not something this control
    /// owns. The hint says where it is owned, because a pill that came back
    /// after a relaunch is otherwise a mystery.
    @MainActor
    static func chips(for filters: RecipeFilterStore) -> [LibraryFilterChip] {
        var chips: [LibraryFilterChip] = []
        if !filters.isDietPaused, filters.hasDiet {
            chips.append(
                LibraryFilterChip(
                    title: filters.diets.dietTitle,
                    hint: """
                        Turns your diet off until the next launch. \
                        Your diet is set in Profile.
                        """,
                    remove: { filters.isDietPaused = true }
                )
            )
        }
        for cuisine in filters.browsingFilter.orderedCuisines {
            chips.append(
                LibraryFilterChip(title: cuisine.title) {
                    filters.browsingFilter.cuisines.remove(cuisine)
                }
            )
        }
        for keyword in filters.browsingFilter.orderedKeywords {
            chips.append(
                LibraryFilterChip(title: keyword.title) {
                    filters.browsingFilter.keywords.remove(keyword)
                }
            )
        }
        for term in filters.browsingFilter.ingredients {
            chips.append(
                LibraryFilterChip(title: "With \(term)") {
                    filters.browsingFilter.removeIngredient(term)
                }
            )
        }
        return chips
    }
}
