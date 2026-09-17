import LadleCore
import Observation
import SwiftUI

/// A recipe page's numbers for its source, and the cook's own stars.
///
/// A Discover preview is seeded from the row it was opened from and asks for
/// nothing. A saved recipe asks the server, and the rating control exists
/// only once it has answered: a server without the ratings API, a recipe
/// with no source and a failed request all leave the page as it was before
/// ratings, with no error to read.
@MainActor
@Observable
final class RecipeEngagementModel {
    private let service: any SourceEngagementServing

    /// The numbers as the server last gave them — or, on a preview, as the
    /// Discover row carried them.
    private(set) var engagement: SourceEngagement?
    /// The stars drawn. It runs ahead of `engagement` while a rating is on
    /// the wire and falls back to it when the write fails.
    private(set) var myRating: Int?
    private(set) var canRate = false
    private(set) var ratingFailed = false
    /// False until the first request has been answered or has failed. The
    /// header holds the line's place until then instead of moving when the
    /// numbers arrive.
    private(set) var isSettled = false
    private var isSending = false

    init(
        service: any SourceEngagementServing,
        preview: DiscoverRecipe? = nil
    ) {
        self.service = service
        engagement = preview.map {
            SourceEngagement(
                sourceID: $0.sourceID,
                savedCount: $0.savedCount,
                likeCount: $0.likeCount,
                ratingAverage: $0.ratingAverage,
                ratingCount: $0.ratingCount
            )
        }
    }

    func load(sourceID: UUID?) async {
        guard let sourceID else { return }
        defer { isSettled = true }
        guard let loaded = try? await service.fetchEngagement(
            sourceID: sourceID
        ) else { return }
        engagement = loaded
        myRating = loaded.myRating
        canRate = true
    }

    /// Optimistic: the stars fill at once. `nil` clears the rating.
    ///
    /// One write is on the wire at a time and the loop sends whatever the
    /// cook last chose, so two quick taps cannot reach the server out of
    /// order. The answer replaces the header's numbers, which is how the
    /// cook sees their rating move the average.
    func rate(_ stars: Int?) async {
        guard canRate, stars != myRating else { return }
        myRating = stars
        ratingFailed = false
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        while let confirmed = engagement, myRating != confirmed.myRating {
            let wanted = myRating
            do {
                let updated = if let wanted {
                    try await service.rate(
                        sourceID: confirmed.sourceID,
                        stars: wanted
                    )
                } else {
                    try await service.clearRating(
                        sourceID: confirmed.sourceID
                    )
                }
                engagement = updated
                if myRating == wanted {
                    myRating = updated.myRating
                }
            } catch {
                myRating = confirmed.myRating
                ratingFailed = true
            }
        }
    }
}

/// One to five stars for a saved recipe's source, near the end of the page.
struct RecipeRatingCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.ladleAccent) private var accent

    let model: RecipeEngagementModel

    /// Symbols do not follow Dynamic Type here, so the stars step up a role
    /// at accessibility sizes: beside text that large a 28-point star reads
    /// as small print, and the stars are the control.
    private var starSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize
            ? LadleTheme.IconSize.hero
            : LadleTheme.IconSize.feature
    }

    /// Never under the 44-point minimum, which is exactly what a 28-point
    /// star with eight points around it comes to.
    private var starTarget: CGFloat {
        max(
            LadleTheme.Control.hitTarget,
            starSize + 2 * LadleTheme.Spacing.compact
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
            Text(model.myRating == nil ? "Rate this recipe" : "Your rating")
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.Label.primary)
            stars
            footer
            if model.ratingFailed {
                Text("Couldn’t save your rating. Try again.")
                    .accessibilityIdentifier("recipe.rating.failure")
            }
        }
        .ladleFont(.metadata)
        .foregroundStyle(LadleTheme.Label.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(LadleTheme.Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ladleCard()
        .sensoryFeedback(.selection, trigger: model.myRating)
        .onChange(of: model.ratingFailed) { _, failed in
            guard failed else { return }
            AccessibilityNotification.Announcement(
                "Couldn’t save your rating."
            )
            .post()
        }
    }

    private var stars: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                let isFilled = star <= model.myRating ?? 0
                Button {
                    rate(star)
                } label: {
                    Image(systemName: isFilled ? "star.fill" : "star")
                        .font(.system(size: starSize))
                        .foregroundStyle(
                            isFilled
                                ? accent.label
                                : LadleTheme.Label.secondary
                        )
                        .frame(width: starTarget, height: starTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(LadlePressButtonStyle())
            }
        }
        // The glyph sits inside its target, so the row steps back by that
        // much to land the first star on the title's leading edge.
        .padding(.leading, (starSize - starTarget) / 2)
        // One adjustable element, the way VoiceOver meets a rating control:
        // swipe up or down on "Your rating" rather than five stars in a row.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your rating")
        .accessibilityValue(
            model.myRating.map { countText($0, "star") } ?? "Not rated"
        )
        .accessibilityAdjustableAction { direction in
            let current = model.myRating ?? 0
            switch direction {
            case .increment: rate(min(current + 1, 5))
            case .decrement: rate(current > 1 ? current - 1 : nil)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("recipe.rating")
    }

    /// One line of metadata in both states, so the card does not change
    /// height under the cook's finger on the tap that rates.
    @ViewBuilder
    private var footer: some View {
        if model.myRating == nil {
            Text("Counts toward the average other cooks see.")
        } else {
            let grow = LadleTheme.Spacing.regular
            Button {
                rate(nil)
            } label: {
                Text("Clear rating")
                    .foregroundStyle(accent.label)
                    // A line of metadata is 18 points tall and a target is
                    // 44. It grows sideways and down, into the card's own
                    // padding — never up, where it would take the presses
                    // meant for the stars.
                    .contentShape(
                        Rectangle().inset(by: -grow).offset(y: grow)
                    )
            }
            .buttonStyle(LadlePressButtonStyle())
            .accessibilityIdentifier("recipe.rating.clear")
        }
    }

    private func rate(_ stars: Int?) {
        Task { await model.rate(stars) }
    }
}
