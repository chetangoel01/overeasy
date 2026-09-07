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
    ///
    /// Both numbers are whole. They come from a normalizer's guess at
    /// unquantified amounts and a USDA row matched by search, and two
    /// refreshes of the same recipe differ by a few percent. A tenth of a
    /// gram claims a precision the pipeline does not have, and reads as
    /// measured in a way that a whole gram does not.
    var libraryFacts: String {
        [
            libraryNutrition?.calories.map {
                "\(ladleNumber($0, maximumFractionDigits: 0)) cal"
            },
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
    /// The measured amount — "2 cups", or "4" for something counted. This is
    /// the form that can be scaled, because it is the only one holding a
    /// number: scaling a recipe renders it from `normalizedQuantity` times
    /// the factor, in place of whatever the creator said.
    ///
    /// Two fraction digits, not the one `ladleNumber` defaults to. A tenth
    /// of a gram is false precision on a nutrition panel, but a quarter of a
    /// cup is an amount somebody measures, and rounding 0.25 to "0.3" would
    /// be wrong in the kitchen.
    func measuredAmount(_ quantity: Decimal) -> String {
        [ladleNumber(quantity, maximumFractionDigits: 2), unit?.nonEmpty]
            .compactMap(\.self)
            .joined(separator: " ")
    }

    /// The amount at the head of an ingredient row.
    ///
    /// `quantityText` is what the creator said, verbatim — "100 g", "2 16oz
    /// cans" — and `normalizedQuantity` with `unit` is the importer's split
    /// of that same phrase, not a second fact about it. Printing both says
    /// the unit twice, which is what a TestFlight tester saw. So the
    /// creator's words win outright, and the split is the fallback for a row
    /// that has no verbatim text of its own. The two forms never combine.
    ///
    /// A `unit` with no amount either side of it is not an amount: a row
    /// reading "cups flour" is worse than one reading "flour".
    var amountText: String? {
        quantityText?.nonEmpty ?? normalizedQuantity.map(measuredAmount)
    }

    var cookingDetailText: String {
        var parts = [amountText, name.nonEmpty].compactMap(\.self)
        if let preparation = preparation?.nonEmpty {
            parts.append("— \(preparation)")
        }
        return parts.joined(separator: " ")
    }
}

private extension String {
    /// A field that is present but blank. The wire contract types every one
    /// of these as an optional string and promises no trimming, so an empty
    /// one has to read as absent rather than as an extra space in the row.
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
