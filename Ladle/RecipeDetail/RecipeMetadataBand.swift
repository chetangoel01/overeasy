import Foundation
import LadleCore
import SwiftUI

struct RecipeMetadataBand: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.ladleAccent) private var accent

    let recipe: Recipe

    /// The cook-time serving count, on a page that can be scaled. The
    /// reimport sheet draws the same band over a candidate the cook is
    /// comparing rather than cooking from, and passes nothing, so its yield
    /// stays the plain read-only fact it is today.
    var scaling: Binding<RecipeScaling>?

    @State private var isServingsPresented = false
    @State private var servingsWhenOpened: Decimal?

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

    /// The yield, and on a scalable recipe the control for it. The band's
    /// own text is the control: a cook thinking "I need six" is looking at
    /// the number that says four, and that is where the tap belongs.
    @ViewBuilder
    private var yieldItem: some View {
        if let scaling, scaling.wrappedValue.isAvailable {
            Button {
                servingsWhenOpened = scaling.wrappedValue.servings
                isServingsPresented = true
            } label: {
                metadataItem(
                    value: yieldValue(scaling.wrappedValue),
                    label: yieldLabel(scaling.wrappedValue),
                    systemImage: "person.2",
                    isAdjustable: true
                )
            }
            .buttonStyle(LadlePressButtonStyle())
            .accessibilityIdentifier("recipe.yield")
            .accessibilityLabel("Servings")
            .accessibilityValue(yieldAccessibilityValue(scaling.wrappedValue))
            .accessibilityHint("Adjusts the serving count and scales the ingredients")
            // Announced when the sheet closes, not on every press of the
            // stepper: the stepper reads its own value as it changes, and a
            // cook stepping four to eight would otherwise hear each count
            // twice. What VoiceOver needs is what the page settled on.
            .sheet(
                isPresented: $isServingsPresented,
                onDismiss: {
                    guard
                        scaling.wrappedValue.servings != servingsWhenOpened
                    else { return }
                    AccessibilityNotification.Announcement(
                        scaledAnnouncement(scaling.wrappedValue)
                    )
                    .post()
                }
            ) {
                ServingsSheet(scaling: scaling)
            }
        } else {
            metadataItem(
                value: recipe.ladleYieldText,
                label: "Yield",
                systemImage: "person.2"
            )
        }
    }

    /// The chosen count while scaled, and the recipe's own claim otherwise.
    private func yieldValue(_ scaling: RecipeScaling) -> String {
        scaling.isScaled ? scaling.chosenYieldText : recipe.ladleYieldText
    }

    /// A scaled band cannot leave "Yield" under a number the recipe never
    /// claimed, so the label carries what it was scaled from. The phrase is
    /// built from the count rather than `ladleYieldText`, which hedges an
    /// uncertain yield with "About" and reads as "Scaled from Yield unknown".
    private func yieldLabel(_ scaling: RecipeScaling) -> String {
        scaling.isScaled ? "Scaled from \(scaling.baseYieldText)" : "Yield"
    }

    private func yieldAccessibilityValue(_ scaling: RecipeScaling) -> String {
        scaling.isScaled
            ? "\(scaling.chosenYieldText), scaled from \(scaling.baseYieldText)"
            : recipe.ladleYieldText
    }

    private func scaledAnnouncement(_ scaling: RecipeScaling) -> String {
        scaling.isScaled
            ? "Scaled to \(scaling.chosenYieldText). Ingredient amounts updated."
            : "Back to the recipe as written."
    }

    private func metadataItem(
        value: String,
        label: String,
        systemImage: String,
        isAdjustable: Bool = false
    ) -> some View {
        VStack(spacing: LadleTheme.Spacing.compact) {
            Image(systemName: systemImage)
                .font(.system(size: LadleTheme.IconSize.small, weight: .semibold))
                .foregroundStyle(accent.label)
                .accessibilityHidden(true)
            HStack(spacing: LadleTheme.Spacing.tight) {
                Text(value)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.primary)
                    .lineLimit(usesVerticalLayout ? 2 : 1)
                    .minimumScaleFactor(usesVerticalLayout ? 1 : 0.78)
                // The one thing marking the yield as a control rather than a
                // fact. iOS spells an adjustable value this way in Settings
                // and in menus, so it needs no other decoration.
                if isAdjustable {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(
                            .system(
                                size: LadleTheme.IconSize.small,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(LadleTheme.Label.secondary)
                        .accessibilityHidden(true)
                }
            }
            Text(label)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.primary.opacity(0.56))
                // No line limit, as before: "Scaled from 4 servings" is
                // longer than the labels this band was built for, and it
                // wraps inside a half-width tile at large type rather than
                // truncating to "Scaled from 4 ser…".
                .multilineTextAlignment(.center)
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

/// The servings stepper the yield opens.
///
/// Deliberately small: one control, the sentence that says what it does and
/// that it is not saved, and a way back to the recipe's own number. Nothing
/// here writes to the recipe.
private struct ServingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var scaling: RecipeScaling

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: LadleTheme.Layout.rowGap) {
                stepperRow

                Text(
                    "Ingredient amounts are recalculated from the recipe’s \(scaling.baseYieldText). Nothing is saved — leaving the recipe puts it back."
                )
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if scaling.isScaled {
                    Button("Reset to \(scaling.baseYieldText)") {
                        scaling.reset()
                    }
                    .buttonStyle(LadleButtonStyle(role: .secondary))
                    .accessibilityIdentifier("recipe.servings.reset")
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, LadleTheme.Spacing.regular)
            .padding(.top, LadleTheme.Spacing.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LadleTheme.Surface.porcelain)
            .navigationTitle("Cooking for")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("recipe.servings.done")
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(LadleTheme.Surface.porcelain)
    }

    private var stepperRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                Text("Servings")
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.primary.opacity(0.58))
                Text(scaling.chosenYieldText)
                    .ladleFont(.recipeTitle)
                    .foregroundStyle(LadleTheme.Label.primary)
            }

            Spacer()

            // The arrows disable themselves at the ends of the range instead
            // of silently refusing, which is what a native stepper does.
            Stepper(
                "Servings",
                onIncrement: scaling.canIncrease
                    ? { scaling.step(by: 1) }
                    : nil,
                onDecrement: scaling.canDecrease
                    ? { scaling.step(by: -1) }
                    : nil
            )
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Servings")
            .accessibilityValue(scaling.chosenYieldText)
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
                    if displayed.approximate {
                        // The estimate is also short by an ingredient; the
                        // sheet names which.
                        Text("Partial")
                            .ladleFont(.metadata)
                            .foregroundStyle(accent.label)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(LadleTheme.Surface.steel, in: Capsule())
                            .accessibilityLabel("Partial: some ingredients were not counted")
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
        nutritionItem(value: displayed.ladleCalorieText, label: "Calories")
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
            ?? Nutrition(
                servingBasis: 1,
                isEstimated: nutrition.isEstimated,
                approximate: nutrition.approximate
            )
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
