import Foundation
import LadleCore
import SwiftUI

struct RecipeMetadataBand: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recipe: Recipe

    var body: some View {
        Group {
            if usesVerticalLayout {
                VStack(spacing: 0) {
                    totalTimeItem
                    horizontalDivider
                    yieldItem
                }
            } else {
                HStack(spacing: 0) {
                    totalTimeItem
                    verticalDivider
                    yieldItem
                }
            }
        }
        .padding(.vertical, 16)
        .background(
            LadleTheme.field,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    private var totalTimeItem: some View {
        metadataItem(
            value: recipe.totalMinutes.map { "\($0) min" } ?? "—",
            label: "Total time",
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
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LadleTheme.paprika)
                .accessibilityHidden(true)
            Text(value)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
                .lineLimit(usesVerticalLayout ? 2 : 1)
                .minimumScaleFactor(usesVerticalLayout ? 1 : 0.78)
            Text(label)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.56))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, usesVerticalLayout ? 10 : 0)
        .accessibilityElement(children: .combine)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(LadleTheme.ink.opacity(0.1))
            .frame(width: 1, height: 48)
            .accessibilityHidden(true)
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(LadleTheme.ink.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 18)
            .accessibilityHidden(true)
    }

    private var usesVerticalLayout: Bool {
        dynamicTypeSize >= .xxxLarge
    }
}

struct RecipeNutritionSummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let nutrition: Nutrition
    let openDetails: () -> Void

    var body: some View {
        Button(action: openDetails) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Nutrition per serving")
                        .ladleFont(.bodyStrong)
                        .foregroundStyle(LadleTheme.ink)
                    if displayed.isEstimated {
                        Text("Estimated")
                            .ladleFont(.metadata)
                            .foregroundStyle(LadleTheme.accentText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(LadleTheme.review, in: Capsule())
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LadleTheme.mutedInk)
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
                LadleTheme.field,
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
        VStack(spacing: 3) {
            Text(value ?? "—")
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
            Text(label)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.mutedInk)
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
    var ladleYieldText: String {
        let value = ladleNumber(servings)
        let noun = servings == 1 ? "serving" : "servings"
        if uncertainties.contains(where: { $0.field == "servings" }) {
            return servings == 1 ? "Yield unknown" : "About \(value) \(noun)"
        }
        return "\(value) \(noun)"
    }
}
