import Foundation
import LadleCore

extension Nutrition {
    var perServing: Nutrition? {
        servingBasis > 0 ? scaled(toServings: 1) : nil
    }
}

extension Recipe {
    var libraryNutrition: Nutrition? {
        nutrition?.perServing
    }

    var libraryFacts: String {
        [
            libraryNutrition?.proteinGrams.map { "\(number($0)) g P" },
            totalMinutes.map { "\($0) min" },
            libraryNutrition?.calories.map { "≈ \(number($0)) cal" },
        ]
        .compactMap(\.self)
        .joined(separator: " · ")
    }

    var librarySlug: String {
        title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private func number(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

extension RecipeSource {
    var libraryTitle: String {
        switch self {
        case .tiktok: "TikTok"
        case .instagram: "Instagram"
        case .youtube: "YouTube"
        case .other: "Saved recipe"
        }
    }
}

extension Ingredient {
    var cookingDetailText: String {
        var parts = [quantityText, unit]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        parts.append(name)
        if let preparation, !preparation.isEmpty {
            parts.append("— \(preparation)")
        }
        return parts.joined(separator: " ")
    }
}
