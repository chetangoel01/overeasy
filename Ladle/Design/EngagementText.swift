import LadleCore
import SwiftUI

/// The words for a shared source's numbers, in one place for the recipe
/// header, Discover's rows and Watch.
///
/// Each number says what it counts and whose count it is: likes are the
/// source platform's, stars and saves are Overeasy's. One that nobody knows
/// — or a zero, which would read as a verdict nobody gave — is nil rather
/// than drawn.
struct EngagementText: Equatable {
    /// The platform's likes as captured at import: "24K likes".
    let likes: String?
    /// The average, only once the server publishes one: "4.6".
    let stars: String?
    /// How many cooks are behind the average, and only ever beside it:
    /// "(12)".
    let raters: String?
    /// "Saved by 18 cooks".
    let saves: String?
    /// Overeasy's numbers in words, because a star glyph is not one.
    let spoken: String?

    init(
        likeCount: Int?,
        ratingAverage: Double?,
        ratingCount: Int,
        savedCount: Int
    ) {
        likes = likeCount.flatMap { count in
            count > 0
                ? "\(count.formatted(.number.notation(.compactName))) "
                    + (count == 1 ? "like" : "likes")
                : nil
        }
        saves = savedCount > 0
            ? "Saved by \(countText(savedCount, "cook"))"
            : nil
        guard let ratingAverage, ratingCount > 0 else {
            stars = nil
            raters = nil
            spoken = saves
            return
        }
        let average = ratingAverage.formatted(
            .number.precision(.fractionLength(1))
        )
        stars = average
        raters = "(\(ratingCount))"
        spoken = [
            "Rated \(average) out of 5 by \(countText(ratingCount, "cook"))",
            saves,
        ].compactMap(\.self).joined(separator: ". ")
    }

    /// Whether Overeasy has a line of its own to draw for the source.
    var hasLine: Bool { spoken != nil }

    init(_ recipe: DiscoverRecipe) {
        self.init(
            likeCount: recipe.likeCount,
            ratingAverage: recipe.ratingAverage,
            ratingCount: recipe.ratingCount,
            savedCount: recipe.savedCount
        )
    }

    init(_ engagement: SourceEngagement) {
        self.init(
            likeCount: engagement.likeCount,
            ratingAverage: engagement.ratingAverage,
            ratingCount: engagement.ratingCount,
            savedCount: engagement.savedCount
        )
    }
}

/// Overeasy's own numbers as metadata: "★ 4.6 (12) · Saved by 18 cooks".
///
/// One line where it fits, and the stars over the saves where it does not. A
/// Discover row's column is narrower than the line, and a run of text breaks
/// wherever the words run out — "Saved by" on one line and "18 cooks" on the
/// next. The caller sets the font and the quieter colour on the whole; the
/// star and the average take `emphasis`. Nothing to say draws nothing.
struct EngagementLine: View {
    let text: EngagementText
    var emphasis = LadleTheme.Label.primary

    var body: some View {
        Group {
            if let rating, let saves = text.saves {
                ViewThatFits(in: .horizontal) {
                    Text("\(rating) · \(saves)")
                        .lineLimit(1)
                    VStack(
                        alignment: .leading,
                        spacing: LadleTheme.Spacing.tight
                    ) {
                        rating
                        Text(saves)
                    }
                }
            } else if let line = rating ?? text.saves.map({ Text($0) }) {
                line
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.spoken ?? "")
    }

    /// The symbol rather than the "★" character, so the star takes the
    /// text's size and weight at every Dynamic Type setting.
    private var rating: Text? {
        guard let stars = text.stars, let raters = text.raters else {
            return nil
        }
        let average = Text("\(Image(systemName: "star.fill")) \(stars)")
            .foregroundStyle(emphasis)
        return Text("\(average) \(raters)")
    }
}
