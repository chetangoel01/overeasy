import Foundation
import LadleCore
import SwiftUI

struct NutritionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let nutrition: Nutrition
    let recipeTitle: String
    let healthService: any HealthService

    @State private var isHealthExportPresented = false

    init(
        nutrition: Nutrition,
        recipeTitle: String,
        healthService: any HealthService = HealthKitService()
    ) {
        self.nutrition = nutrition
        self.recipeTitle = recipeTitle
        self.healthService = healthService
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    calorieHero
                    macroGrid
                    nutrientList
                    servingNote
                    if hasValidServingBasis {
                        healthExportButton
                    }
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
        .sheet(isPresented: $isHealthExportPresented) {
            HealthExportSheet(
                recipeTitle: recipeTitle,
                nutrition: nutrition,
                service: healthService
            )
        }
    }

    private var calorieHero: some View {
        VStack(spacing: LadleTheme.Spacing.tight) {
            Text(calorieText)
                .ladleFont(.display)
                .foregroundStyle(LadleTheme.ink)
            Text("Calories")
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink.opacity(0.58))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            LadleTheme.Surface.steel,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            hasValidServingBasis
                ? "\(displayedNutrition.isEstimated ? "Estimated " : "")\(calorieText) calories"
                : "Nutrition per serving unavailable"
        )
    }

    private var macroGrid: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: LadleTheme.Layout.rowGap) {
                    macros
                }
            } else {
                HStack(spacing: LadleTheme.Layout.rowGap) {
                    macros
                }
            }
        }
    }

    @ViewBuilder
    private var macros: some View {
        macro(
            name: "Protein",
            value: displayedNutrition.proteinGrams,
            color: LadleTheme.Intent.success
        )
        macro(
            name: "Carbohydrates",
            value: displayedNutrition.carbohydrateGrams,
            color: LadleTheme.Label.accent
        )
        macro(
            name: "Fat",
            value: displayedNutrition.fatGrams,
            color: LadleTheme.ink
        )
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
        VStack(alignment: .leading, spacing: LadleTheme.Layout.rowGap) {
            Label(
                hasValidServingBasis
                    ? "Per serving"
                    : "Serving basis unavailable",
                systemImage: hasValidServingBasis
                    ? "person.crop.circle"
                    : "exclamationmark.circle"
            )
            .ladleFont(.bodyStrong)
            .foregroundStyle(LadleTheme.ink)

            if !hasValidServingBasis {
                Text(
                    "Set a valid serving basis before using these values or exporting them."
                )
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.64))
            } else if displayedNutrition.isEstimated {
                Label(
                    "Nutrition is estimated from the imported recipe.",
                    systemImage: "info.circle"
                )
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.64))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LadleTheme.Surface.raised,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    private var healthExportButton: some View {
        Button {
            isHealthExportPresented = true
        } label: {
            Label(
                "Export to Apple Health",
                systemImage: "heart.text.clipboard"
            )
        }
        .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
    }

    private func macro(
        name: String,
        value: Decimal?,
        color: Color
    ) -> some View {
        let valueText = value.map { "\(ladleNumber($0)) g" } ?? "Unavailable"

        return VStack(spacing: LadleTheme.Spacing.compact) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(valueText)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
            Text(name)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .ladleCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(valueText)")
        .accessibilityIdentifier("nutrition.macro.\(name.lowercased())")
    }

    private func nutrientRow(_ nutrient: NutritionDisplayRow) -> some View {
        HStack {
            Text(nutrient.name)
                .ladleFont(.body)
            Spacer()
            Text("\(ladleNumber(nutrient.amount)) \(nutrient.unit)")
                .ladleFont(.bodyStrong)
        }
        .foregroundStyle(LadleTheme.ink)
        .padding(.vertical, LadleTheme.Spacing.medium)
    }

    private var nutrientDivider: some View {
        Divider()
            .overlay(LadleTheme.ink.opacity(0.08))
    }

    private var nutrientRows: [NutritionDisplayRow] {
        [
            displayedNutrition.saturatedFatGrams.map {
                NutritionDisplayRow(
                    name: "Saturated fat",
                    amount: $0,
                    unit: "g"
                )
            },
            displayedNutrition.fiberGrams.map {
                NutritionDisplayRow(
                    name: "Fiber",
                    amount: $0,
                    unit: "g"
                )
            },
            displayedNutrition.sugarGrams.map {
                NutritionDisplayRow(
                    name: "Sugar",
                    amount: $0,
                    unit: "g"
                )
            },
            displayedNutrition.sodiumMilligrams.map {
                NutritionDisplayRow(
                    name: "Sodium",
                    amount: $0,
                    unit: "mg"
                )
            },
        ]
        .compactMap { $0 }
        + displayedNutrition.otherNutrients.map {
            NutritionDisplayRow(
                id: $0.id.uuidString,
                name: $0.name,
                amount: $0.amount,
                unit: $0.unit
            )
        }
    }

    private var calorieText: String {
        guard let calories = displayedNutrition.calories else {
            return "—"
        }
        let prefix = displayedNutrition.isEstimated ? "≈ " : ""
        return "\(prefix)\(ladleNumber(calories, maximumFractionDigits: 0))"
    }

    private var displayedNutrition: Nutrition {
        nutrition.perServing
            ?? Nutrition(
                servingBasis: 1,
                isEstimated: nutrition.isEstimated
            )
    }

    private var hasValidServingBasis: Bool {
        nutrition.perServing != nil
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
