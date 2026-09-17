import Foundation
import LadleCore
import SwiftUI

struct NutritionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let nutrition: Nutrition
    let recipeTitle: String
    /// What the totals leave out, when they leave anything out.
    let uncountedNote: String?
    let healthService: any HealthService

    @State private var isHealthExportPresented = false

    init(
        nutrition: Nutrition,
        recipeTitle: String,
        uncountedNote: String? = nil,
        healthService: any HealthService = HealthKitService()
    ) {
        self.nutrition = nutrition
        self.recipeTitle = recipeTitle
        self.uncountedNote = uncountedNote
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
            .background(LadleTheme.Surface.porcelain)
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
            .navigationDestination(isPresented: $isHealthExportPresented) {
                HealthExportSheet(
                    recipeTitle: recipeTitle,
                    nutrition: nutrition,
                    uncountedNote: uncountedNote,
                    service: healthService
                )
            }
        }
        .presentationDetents([.large])
        .presentationBackground(LadleTheme.Surface.porcelain)
    }

    private var calorieHero: some View {
        VStack(spacing: LadleTheme.Spacing.tight) {
            Text(calorieText)
                .ladleFont(.display)
                .foregroundStyle(LadleTheme.Label.primary)
            Text("Calories")
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.Label.secondary)
            if let macroCalories {
                calorieSources(macroCalories)
                    .padding(.top, LadleTheme.Spacing.medium)
            }
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
                ? spokenCalorieText
                : "Nutrition per serving unavailable"
        )
    }

    /// One bar, each segment as wide as its macro's share of the calories.
    ///
    /// The tiles below are its legend — a segment wears its tile's dot, in
    /// the tiles' order — and they carry every number, so the bar says
    /// nothing to VoiceOver that the tiles do not. Widths come from the
    /// percentages the tiles print, so the two cannot disagree, and a macro
    /// with no share draws no segment rather than a stray gap.
    private func calorieSources(_ macros: MacroCalories) -> some View {
        let segments = [
            (share: macros.protein, color: MacroColor.protein),
            (share: macros.carbohydrate, color: MacroColor.carbohydrate),
            (share: macros.fat, color: MacroColor.fat),
        ]
        .filter { $0.share.percent > 0 }

        return VStack(spacing: LadleTheme.Spacing.compact) {
            Text("Calories from")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
            GeometryReader { geometry in
                let gap = LadleTheme.Spacing.tight
                let width = geometry.size.width
                    - gap * CGFloat(segments.count - 1)
                HStack(spacing: gap) {
                    ForEach(segments.indices, id: \.self) { index in
                        let segment = segments[index]
                        segment.color.frame(
                            width: width * CGFloat(segment.share.percent) / 100
                        )
                    }
                }
            }
            .frame(height: 12)
            .clipShape(Capsule())
        }
        .padding(.horizontal, LadleTheme.Layout.cardPadding)
        .accessibilityHidden(true)
    }

    private var macroGrid: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Layout.rowGap) {
            macroTiles
            if let macroCalories {
                let note = NutritionNote.macroCalories(
                    macroCalories,
                    of: displayedNutrition.calories
                )
                Text(note)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.secondary)
                    .accessibilityLabel(
                        note.replacingOccurrences(of: "kcal", with: "calories")
                    )
            }
        }
    }

    private var macroTiles: some View {
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
            share: macroCalories?.protein,
            color: MacroColor.protein
        )
        macro(
            name: "Carbohydrates",
            value: displayedNutrition.carbohydrateGrams,
            share: macroCalories?.carbohydrate,
            color: MacroColor.carbohydrate
        )
        macro(
            name: "Fat",
            value: displayedNutrition.fatGrams,
            share: macroCalories?.fat,
            color: MacroColor.fat
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
            .foregroundStyle(LadleTheme.Label.primary)

            if !hasValidServingBasis {
                Text(
                    "Set a valid serving basis before using these values or exporting them."
                )
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
            } else if displayedNutrition.isEstimated {
                Label(
                    "Nutrition is estimated from the imported recipe.",
                    systemImage: "info.circle"
                )
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
            }

            // A total that leaves an ingredient out has to say so where the
            // total is read, not only beside the ingredient it skipped.
            if hasValidServingBasis, let uncountedNote {
                Label(uncountedNote, systemImage: "exclamationmark.circle")
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.secondary)
                    .accessibilityIdentifier("nutrition.uncounted")
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
        .buttonStyle(LadleButtonStyle(role: .secondary))
    }

    private func macro(
        name: String,
        value: Decimal?,
        share: MacroCalories.Share?,
        color: Color
    ) -> some View {
        let valueText = value.map { "\(ladleNumber($0)) g" } ?? "Unavailable"
        let calories = share.map {
            ladleNumber($0.calories, maximumFractionDigits: 0)
        }

        return VStack(spacing: LadleTheme.Spacing.compact) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(valueText)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.Label.primary)
            Text(name)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if let share, let calories {
                // Three tiles across leave each about 110 points, which
                // "152 kcal · 23%" outgrows past the default text size, so
                // there it breaks at the dot instead of shrinking.
                let breaks = dynamicTypeSize > .large
                    && !dynamicTypeSize.isAccessibilitySize
                Text("\(calories) kcal\(breaks ? "\n" : " · ")\(share.percent)%")
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(breaks ? 2 : 1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .ladleCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [
                name,
                valueText,
                calories.map { "\($0) calories" },
                share.map { "\($0.percent) percent" },
            ]
            .compactMap(\.self)
            .joined(separator: ", ")
        )
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
        .foregroundStyle(LadleTheme.Label.primary)
        .padding(.vertical, LadleTheme.Spacing.medium)
    }

    private var nutrientDivider: some View {
        Divider()
            .overlay(LadleTheme.Label.primary.opacity(0.08))
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
        displayedNutrition.ladleEstimatedCalorieText ?? "—"
    }

    /// The hero read aloud. VoiceOver announces "≈" as a symbol, so the
    /// marker becomes the word the metadata band already uses for a time it
    /// is not sure of.
    private var spokenCalorieText: String {
        guard let calories = displayedNutrition.calories else {
            return "Calories unavailable"
        }
        let number = ladleNumber(calories, maximumFractionDigits: 0)
        return displayedNutrition.isEstimated || displayedNutrition.approximate
            ? "About \(number) calories"
            : "\(number) calories"
    }

    private var displayedNutrition: Nutrition {
        nutrition.perServing
            ?? Nutrition(
                servingBasis: 1,
                isEstimated: nutrition.isEstimated,
                approximate: nutrition.approximate
            )
    }

    private var hasValidServingBasis: Bool {
        nutrition.perServing != nil
    }

    /// Per serving, like every other figure here. Nil — so no bar, no kcal
    /// lines and no note — when a macro is missing or the serving basis is
    /// unusable, because an unavailable value is never drawn as zero.
    private var macroCalories: MacroCalories? {
        displayedNutrition.macroCalories
    }

}

/// A tile's dot and its segment of the bar read the same role, which is what
/// lets the dots stand as the bar's legend.
private enum MacroColor {
    static let protein = LadleTheme.Intent.success
    static let carbohydrate = LadleTheme.Label.secondary
    static let fat = LadleTheme.Label.primary
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
