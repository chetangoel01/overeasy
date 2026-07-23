import Foundation
import LadleCore
import SwiftUI

struct NutritionView: View {
    @Environment(\.dismiss) private var dismiss

    let nutrition: Nutrition

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    calorieHero
                    macroGrid
                    nutrientList
                    servingNote
                }
                .padding(LadleTheme.Spacing.generous)
            }
            .scrollIndicators(.hidden)
            .background(LadleTheme.paper)
            .accessibilityIdentifier("nutrition.detail")
            .navigationTitle("Nutrition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LadleTheme.paper)
    }

    private var calorieHero: some View {
        VStack(spacing: 5) {
            Text(calorieText)
                .font(LadleTypography.display)
                .foregroundStyle(LadleTheme.ink)
            Text("Calories")
                .font(LadleTypography.bodyStrong)
                .foregroundStyle(LadleTheme.ink.opacity(0.58))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            LadleTheme.review,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(nutrition.isEstimated ? "Estimated " : "")\(calorieText) calories"
        )
    }

    private var macroGrid: some View {
        HStack(spacing: 10) {
            macro(
                name: "Protein",
                value: nutrition.proteinGrams,
                color: LadleTheme.success
            )
            macro(
                name: "Carbohydrates",
                value: nutrition.carbohydrateGrams,
                color: LadleTheme.paprika
            )
            macro(
                name: "Fat",
                value: nutrition.fatGrams,
                color: LadleTheme.ink
            )
        }
    }

    private var nutrientList: some View {
        VStack(spacing: 0) {
            ForEach(Array(nutrientRows.enumerated()), id: \.element.id) {
                index,
                nutrient in
                nutrientRow(nutrient)

                if index < nutrientRows.count - 1 {
                    nutrientDivider
                }
            }
        }
        .padding(.horizontal, 16)
        .ladleCard()
    }

    private var servingNote: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Per \(decimalText(nutrition.servingBasis)) serving",
                systemImage: "person.crop.circle"
            )
            .font(LadleTypography.bodyStrong)
            .foregroundStyle(LadleTheme.ink)

            if nutrition.isEstimated {
                Label(
                    "Nutrition is estimated from the imported recipe.",
                    systemImage: "info.circle"
                )
                .font(LadleTypography.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.64))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LadleTheme.field,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    private func macro(
        name: String,
        value: Decimal?,
        color: Color
    ) -> some View {
        VStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(value.map { "\(decimalText($0)) g" } ?? "—")
                .font(LadleTypography.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
            Text(name)
                .font(LadleTypography.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .ladleCard()
    }

    private func nutrientRow(_ nutrient: NutritionDisplayRow) -> some View {
        HStack {
            Text(nutrient.name)
                .font(LadleTypography.body)
            Spacer()
            Text("\(decimalText(nutrient.amount)) \(nutrient.unit)")
                .font(LadleTypography.bodyStrong)
        }
        .foregroundStyle(LadleTheme.ink)
        .padding(.vertical, 14)
    }

    private var nutrientDivider: some View {
        Divider()
            .overlay(LadleTheme.ink.opacity(0.08))
    }

    private var nutrientRows: [NutritionDisplayRow] {
        [
            nutrition.saturatedFatGrams.map {
                NutritionDisplayRow(
                    name: "Saturated fat",
                    amount: $0,
                    unit: "g"
                )
            },
            nutrition.fiberGrams.map {
                NutritionDisplayRow(
                    name: "Fiber",
                    amount: $0,
                    unit: "g"
                )
            },
            nutrition.sugarGrams.map {
                NutritionDisplayRow(
                    name: "Sugar",
                    amount: $0,
                    unit: "g"
                )
            },
            nutrition.sodiumMilligrams.map {
                NutritionDisplayRow(
                    name: "Sodium",
                    amount: $0,
                    unit: "mg"
                )
            },
        ]
        .compactMap { $0 }
        + nutrition.otherNutrients.map {
            NutritionDisplayRow(
                id: $0.id.uuidString,
                name: $0.name,
                amount: $0.amount,
                unit: $0.unit
            )
        }
    }

    private var calorieText: String {
        guard let calories = nutrition.calories else {
            return "—"
        }
        let prefix = nutrition.isEstimated ? "≈ " : ""
        return "\(prefix)\(decimalText(calories))"
    }

    private func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

private struct NutritionDisplayRow: Identifiable {
    let id: String
    let name: String
    let amount: Decimal
    let unit: String

    init(
        id: String? = nil,
        name: String,
        amount: Decimal,
        unit: String
    ) {
        self.id = id ?? name
        self.name = name
        self.amount = amount
        self.unit = unit
    }
}
