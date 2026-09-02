import SwiftUI

/// The actions behind the recipe screen's ellipsis button. These are shown in
/// a native `Menu`: the ellipsis is a "more actions" affordance, so a menu is
/// the platform's answer to it, not a modal sheet.
enum RecipeOption: Identifiable {
    case edit
    case reimport
    case nutrition
    case source
    case delete

    var id: Self { self }

    var title: String {
        switch self {
        case .edit: "Edit recipe"
        case .reimport: "Re-import from source"
        case .nutrition: "View nutrition"
        case .source: "Watch original video"
        case .delete: "Delete recipe"
        }
    }

    var systemImage: String {
        switch self {
        case .edit: "square.and.pencil"
        case .reimport: "arrow.triangle.2.circlepath"
        case .nutrition: "chart.bar"
        case .source: "play.rectangle"
        case .delete: "trash"
        }
    }

    /// Destructive items carry the system's own role so they pick up the
    /// platform's red treatment, and are grouped apart from the rest.
    var isDestructive: Bool {
        self == .delete
    }
}
