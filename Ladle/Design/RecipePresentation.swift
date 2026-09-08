import Foundation
import LadleCore

extension Nutrition {
    var perServing: Nutrition? {
        servingBasis > 0 ? scaled(toServings: 1) : nil
    }

    /// The calorie figure as a card or the metadata band prints it: whole,
    /// and marked only when the totals left an ingredient out. Cards never
    /// carried the estimate marker, and a marker on every card says nothing.
    var ladleCalorieText: String? {
        calories.map {
            ladleApproximate(
                ladleNumber($0, maximumFractionDigits: 0),
                when: approximate
            )
        }
    }

    /// The calorie figure as the nutrition sheet, the Health export and the
    /// Watch feed print it: marked whenever the number is an estimate at
    /// all, which is how those surfaces have always read.
    var ladleEstimatedCalorieText: String? {
        calories.map {
            ladleApproximate(
                ladleNumber($0, maximumFractionDigits: 0),
                when: isEstimated || approximate
            )
        }
    }
}

/// Marks a figure the cook should not take as exact.
///
/// "≈" keeps its everyday meaning — an estimate. The sheet, the Health
/// export and the Watch feed put it on every calculated panel, as they did
/// before; cards and the metadata band only reach for it when the totals
/// are also *incomplete*, so a clean card still means a complete count and
/// the "Partial" pill on the band says which kind of doubt this is. Only
/// calories take the marker: it is the number people scan for, and one
/// caveat on a line reads as a caveat where four read as noise.
///
/// The names of what was skipped are not here. They live on the ingredient
/// rows and in one line on the nutrition sheet, both drawn from the
/// uncertainties the server already sends.
func ladleApproximate(_ text: String, when approximate: Bool) -> String {
    approximate ? "≈ \(text)" : text
}

extension Recipe {
    var libraryNutrition: Nutrition? {
        nutrition?.perServing
    }

    /// The one-line summary under a recipe wherever it appears as a card or
    /// row. Calories lead because they are the number people scan for, and
    /// protein is spelled out: "680 cal · 38g protein".
    ///
    /// A "≈" leads the calories when the total is missing an ingredient, and
    /// appears for nothing else. The card carries the marker alone — no
    /// count, no words — because a cook scanning a shelf needs to know a
    /// number is short before comparing it against another, and nothing more
    /// than that fits at this size. Which ingredients, and why, are on the
    /// nutrition sheet.
    ///
    /// Both numbers are whole. They come from a normalizer's guess at
    /// unquantified amounts and a USDA row matched by search, and two
    /// refreshes of the same recipe differ by a few percent. A tenth of a
    /// gram claims a precision the pipeline does not have, and reads as
    /// measured in a way that a whole gram does not.
    var libraryFacts: String {
        [
            libraryNutrition?.ladleCalorieText.map { "\($0) cal" },
            libraryNutrition?.proteinGrams.map {
                "\(ladleNumber($0, maximumFractionDigits: 0))g protein"
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

/// Halves round away from zero, not to even. Foundation's default would read
/// 24.5 g as 24 and 25.5 g as 26 — the right rule for summing a column
/// without accumulating bias, the wrong one for a single number read once.
func ladleNumber(
    _ value: Decimal,
    maximumFractionDigits: Int = 1
) -> String {
    value.formatted(
        .number
            .precision(.fractionLength(0...maximumFractionDigits))
            .rounded(rule: .toNearestOrAwayFromZero)
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
