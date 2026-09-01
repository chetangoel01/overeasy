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

    /// The one-line summary under a recipe wherever it appears as a card or
    /// row. Calories lead because they are the number people scan for, and
    /// protein is spelled out: "680 cal · 38g protein". The estimated marker
    /// lives on the detail screen's nutrition panel, not here — a "≈" on a
    /// card is noise at this size.
    var libraryFacts: String {
        [
            libraryNutrition?.calories.map {
                "\(ladleNumber($0, maximumFractionDigits: 0)) cal"
            },
            libraryNutrition?.proteinGrams.map {
                "\(ladleNumber($0))g protein"
            },
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

    var creatorAccountLabel: String {
        guard let creatorName,
              !creatorName.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
            return source.libraryTitle
        }
        return creatorName
    }
}

func ladleNumber(
    _ value: Decimal,
    maximumFractionDigits: Int = 1
) -> String {
    value.formatted(
        .number.precision(
            .fractionLength(0...maximumFractionDigits)
        )
    )
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

extension ImportJob {
    var sourceAccountLabel: String? {
        sourceURL.pathComponents.first { component in
            component.hasPrefix("@") && component.count > 1
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
