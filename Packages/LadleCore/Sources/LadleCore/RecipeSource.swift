import Foundation

public enum RecipeSource: String, Codable, CaseIterable, Hashable, Sendable {
    case tiktok
    case instagram
    case youtube
    case other
}
