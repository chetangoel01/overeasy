import LadleCore
import SwiftUI

/// One line of the "About these estimates" note: what was estimated, and the
/// pipeline's own account of how.
struct RecipeEstimateNote: Hashable {
    let subject: String
    let reason: String
}

extension FieldUncertainty {
    /// The normalizer's working for a nutrition amount — "Estimated average
    /// weight of 3 chicken thighs at 125g each". It is true of most rows of
    /// most recipes and nothing a cook acts on, so it is kept off the row.
    ///
    /// Every other note on an ingredient changes how its row should be read
    /// — a doubt about the ingredient itself, or "Not counted" — and stays
    /// there. The reasons are server-authored prose; the field is what tells
    /// them apart.
    var isRoutineEstimate: Bool {
        field.hasSuffix(".nutritionAmount")
    }
}

extension Recipe {
    /// Everything the page estimated, in the order the page shows it: time,
    /// servings, ingredient amounts, nutrition. The values keep their own
    /// short hedge — "About 45 min", "≈ 560" — and the reasons live here,
    /// once. Empty when nothing was estimated, which hides the disclosure.
    var ladleEstimateNotes: [RecipeEstimateNote] {
        var notes: [RecipeEstimateNote] = []
        if let reason = ladleTimeNote {
            notes.append(RecipeEstimateNote(subject: "Time", reason: reason))
        }
        if let reason = ladleYieldNote {
            notes.append(RecipeEstimateNote(subject: "Servings", reason: reason))
        }
        notes += orderedIngredients.compactMap { ingredient in
            guard let note = ingredient.uncertainty, note.isRoutineEstimate else {
                return nil
            }
            return RecipeEstimateNote(
                subject: ingredient.name,
                reason: note.reason
            )
        }
        if nutrition?.isEstimated == true {
            notes.append(
                RecipeEstimateNote(
                    subject: "Nutrition",
                    reason: "Estimated from the ingredient amounts."
                )
            )
        }
        return notes
    }
}

/// The one place the recipe page explains its estimates: a quiet row that
/// opens onto the reasons. Built for this page and nothing else.
struct RecipeEstimatesDisclosure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let notes: [RecipeEstimateNote]

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.compact) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: LadleTheme.Spacing.compact) {
                    Image(systemName: "info.circle")
                    Text("About these estimates")
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(
                            .system(
                                size: LadleTheme.IconSize.small,
                                weight: .semibold
                            )
                        )
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
                .frame(minHeight: LadleTheme.Control.hitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(LadlePressButtonStyle())
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("recipe.estimates")

            if isExpanded {
                VStack(alignment: .leading, spacing: LadleTheme.Layout.rowGap) {
                    ForEach(notes, id: \.self) { note in
                        VStack(
                            alignment: .leading,
                            spacing: LadleTheme.Spacing.tight
                        ) {
                            Text(note.subject)
                                .foregroundStyle(LadleTheme.Label.primary)
                            Text(note.reason)
                                .foregroundStyle(LadleTheme.Label.secondary)
                        }
                        .ladleFont(.metadata)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.bottom, LadleTheme.Spacing.compact)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, LadleTheme.Spacing.compact)
    }
}
