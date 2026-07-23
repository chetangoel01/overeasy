import Foundation
import LadleCore
import SwiftUI

struct RecipeMetadataBand: View {
    let recipe: Recipe

    var body: some View {
        HStack(spacing: 0) {
            metadataItem(
                value: recipe.totalMinutes.map { "\($0) min" } ?? "—",
                label: "Total time",
                systemImage: "clock"
            )

            divider

            metadataItem(
                value: "\(decimalText(recipe.servings)) servings",
                label: "Yield",
                systemImage: "person.2"
            )

            divider

            metadataItem(
                value: calorieText,
                label: "Per serving",
                systemImage: "flame"
            )
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
                .font(LadleTypography.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(label)
                .font(LadleTypography.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.56))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle()
            .fill(LadleTheme.ink.opacity(0.1))
            .frame(width: 1, height: 48)
            .accessibilityHidden(true)
    }

    private var calorieText: String {
        guard let calories = recipe.nutrition?.calories else {
            return "—"
        }
        return "≈ \(decimalText(calories)) cal"
    }

    private func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
