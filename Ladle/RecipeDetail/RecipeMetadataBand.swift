import Foundation
import LadleCore
import SwiftUI

struct RecipeMetadataBand: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recipe: Recipe

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    totalTimeItem
                    horizontalDivider
                    calorieItem
                    horizontalDivider
                    yieldItem
                }
            } else {
                HStack(spacing: 0) {
                    totalTimeItem
                    verticalDivider
                    calorieItem
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

    private var calorieItem: some View {
        metadataItem(
            value: calorieText,
            label: "Per serving",
            systemImage: "flame"
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
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(label)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.56))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 10 : 0)
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

    private var calorieText: String {
        guard let calories = recipe.libraryNutrition?.calories else {
            return "—"
        }
        return "≈ \(decimalText(calories)) cal"
    }

    private func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

extension Recipe {
    var ladleYieldText: String {
        let value = NSDecimalNumber(decimal: servings).stringValue
        let noun = servings == 1 ? "serving" : "servings"
        if uncertainties.contains(where: { $0.field == "servings" }) {
            return servings == 1 ? "Yield unknown" : "About \(value) \(noun)"
        }
        return "\(value) \(noun)"
    }
}
