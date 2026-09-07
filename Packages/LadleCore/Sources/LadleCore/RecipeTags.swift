import Foundation

/// The three closed tag vocabularies a recipe carries, mirroring
/// `Backend/ladle/contracts/tags.py` value for value.
///
/// They are enums rather than strings because every one of them is a filter
/// parameter the server validates: an off-vocabulary value is a 422, and a
/// typo that only shows up as an empty feed is exactly the failure a closed
/// list exists to prevent. Declaration order is the backend's order, and it
/// is what orders both the menu rows and the query parameters — so an
/// encoded request is stable enough to assert on.
///
/// Decoding is deliberately lenient everywhere these appear (see
/// `RemoteTagListDTO`): the curated keyword list is expected to grow, and a
/// build that met a term it had never heard of must drop the term, not the
/// recipe.

public enum DietTag: String, CaseIterable, Codable, Hashable, Sendable {
    case vegetarian
    case vegan
    case pescatarian
    case glutenFree
    case dairyFree
}

public enum CuisineTag: String, CaseIterable, Codable, Hashable, Sendable {
    case american
    case british
    case caribbean
    case chinese
    case french
    case indian
    case italian
    case japanese
    case korean
    case latinAmerican
    case mediterranean
    case mexican
    case middleEastern
    case southeastAsian
    case westAfrican
}

public enum RecipeKeyword: String, CaseIterable, Codable, Hashable, Sendable {
    case onePot
    case weeknight
    case mealPrep
    case highProtein
    case budget
    case comfortFood
    case airFryer
    case slowCooker
    case pressureCooker
    case sheetPan
    case noCook
    case baking
    case grilling
    case freezerFriendly
    case kidFriendly
    case partyFood
    case breakfast
    case brunch
    case lunchbox
    case dessert
    case snack
    case sideDish
    case soup
    case salad
    case pasta
}

extension Sequence where Element: RawRepresentable, Element.RawValue == String {
    /// Raw values in the order the sequence yields them. The one place the
    /// wire spelling of a tag is produced.
    public var tagRawValues: [String] { map(\.rawValue) }
}

extension CaseIterable where Self: Hashable {
    /// The members of `selection`, in declaration order.
    ///
    /// A `Set` has no order, and both the filter menu and the query string
    /// need one that does not move between launches.
    public static func ordered(_ selection: Set<Self>) -> [Self] {
        allCases.filter(selection.contains)
    }
}
