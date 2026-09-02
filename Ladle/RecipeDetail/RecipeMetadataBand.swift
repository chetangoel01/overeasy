import Foundation
import LadleCore
import SwiftUI

struct RecipeMetadataBand: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.ladleAccent) private var accent

    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.compact) {
            Group {
                if usesVerticalLayout {
                    VStack(spacing: 0) {
                        timeItem
                        horizontalDivider
                        yieldItem
                    }
                } else {
                    HStack(spacing: 0) {
                        timeItem
                        verticalDivider
                        yieldItem
                    }
                }
            }
            .padding(.vertical, 16)
            .background(
                LadleTheme.Surface.raised,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
            )

            // Why the number says "About", in the voice ingredient and step
            // notes already use.
            if let note = recipe.ladleTimeNote {
                Label(note, systemImage: "exclamationmark.circle")
                    .ladleFont(.metadata)
                    .foregroundStyle(accent.label)
                    .accessibilityLabel("Estimated time: \(note)")
            }
        }
    }

    private var timeItem: some View {
        let time = recipe.ladleTimeItem
        return metadataItem(
            value: time.value,
            label: time.label,
            systemImage: "clock"
        )
    }

    private var yieldItem: some View {
        metadataItem(
            value: recipe.ladleYieldText,
            label: "Yield",
            systemImage: "person.2"
        )
    }

    private func metadataItem(
        value: String,
        label: String,
        systemImage: String
    ) -> some View {
        VStack(spacing: LadleTheme.Spacing.compact) {
            Image(systemName: systemImage)
                .font(.system(size: LadleTheme.IconSize.small, weight: .semibold))
                .foregroundStyle(accent.label)
                .accessibilityHidden(true)
            Text(value)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.Label.primary)
                .lineLimit(usesVerticalLayout ? 2 : 1)
                .minimumScaleFactor(usesVerticalLayout ? 1 : 0.78)
            Text(label)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.primary.opacity(0.56))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, LadleTheme.Spacing.compact)
        .padding(.vertical, usesVerticalLayout ? LadleTheme.Spacing.medium : 0)
        .accessibilityElement(children: .combine)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(LadleTheme.Label.primary.opacity(0.1))
            .frame(width: 1, height: 48)
            .accessibilityHidden(true)
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(LadleTheme.Label.primary.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, LadleTheme.Spacing.regular)
            .accessibilityHidden(true)
    }

    private var usesVerticalLayout: Bool {
        dynamicTypeSize >= .xxxLarge
    }
}

struct RecipeNutritionSummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.ladleAccent) private var accent

    let nutrition: Nutrition
    let openDetails: () -> Void

    var body: some View {
        Button(action: openDetails) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Nutrition per serving")
                        .ladleFont(.bodyStrong)
                        .foregroundStyle(LadleTheme.Label.primary)
                    if displayed.isEstimated {
                        Text("Estimated")
                            .ladleFont(.metadata)
                            .foregroundStyle(accent.label)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(LadleTheme.Surface.steel, in: Capsule())
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: LadleTheme.IconSize.small, weight: .semibold))
                        .foregroundStyle(LadleTheme.Label.secondary)
                }

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 12
                        ) {
                            nutritionItems
                        }
                    } else {
                        HStack(spacing: 8) {
                            nutritionItems
                        }
                    }
                }
            }
            .padding(16)
            .background(
                LadleTheme.Surface.raised,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
            )
        }
        .buttonStyle(LadlePressButtonStyle())
        .accessibilityHint("Opens full nutrition details")
    }

    @ViewBuilder
    private var nutritionItems: some View {
        nutritionItem(
            value: displayed.calories.map {
                ladleNumber($0, maximumFractionDigits: 0)
            },
            label: "Calories"
        )
        nutritionItem(value: grams(displayed.proteinGrams), label: "Protein")
        nutritionItem(value: grams(displayed.carbohydrateGrams), label: "Carbs")
        nutritionItem(value: grams(displayed.fatGrams), label: "Fat")
    }

    private func nutritionItem(value: String?, label: String) -> some View {
        VStack(spacing: LadleTheme.Spacing.tight) {
            Text(value ?? "—")
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.Label.primary)
            Text(label)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func grams(_ value: Decimal?) -> String? {
        value.map { "\(ladleNumber($0)) g" }
    }

    private var displayed: Nutrition {
        nutrition.perServing
            ?? Nutrition(servingBasis: 1, isEstimated: nutrition.isEstimated)
    }
}

extension Recipe {
    /// The band's time, under the label that is true of it. A recipe that
    /// states only a cook time shows that rather than an em dash, and an
    /// estimated total says "About" the way an estimated yield does.
    var ladleTimeItem: (value: String, label: String) {
        guard let time = displayedTime else { return ("—", "Total time") }
        let value = "\(time.minutes) min"
        return (isTimeEstimated ? "About \(value)" : value, time.label)
    }

    /// The reason an estimated time is an estimate, when there is a number
    /// for it to explain.
    var ladleTimeNote: String? {
        guard displayedTime != nil else { return nil }
        return uncertainties.first { $0.field == "total_minutes" }?.reason
    }

    var ladleYieldText: String {
        let value = ladleNumber(servings)
        let noun = servings == 1 ? "serving" : "servings"
        if uncertainties.contains(where: { $0.field == "servings" }) {
            return servings == 1 ? "Yield unknown" : "About \(value) \(noun)"
        }
        return "\(value) \(noun)"
    }
}
