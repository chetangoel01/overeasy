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

    /// The settled-count announcement that has not been spoken yet.
    @State private var announcement: Task<Void, Never>?

    /// The drawn minus and plus. Their targets are 44 points regardless.
    private static let stepDiameter: CGFloat = 30

    /// Room for two digits, so stepping nine to ten does not slide the plus
    /// out from under the finger that is pressing it.
    private static let countMinWidth: CGFloat = 32

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

    /// The yield, and on a scalable recipe the control for it, in place: a
    /// cook thinking "I need six" is looking at the number that says four,
    /// and changing it should not cost a sheet and a Done.
    @ViewBuilder
    private var yieldItem: some View {
        if let scaling, scaling.wrappedValue.isAvailable {
            servingsStepper(scaling)
        } else {
            metadataItem(
                value: recipe.ladleYieldText,
                label: "Yield",
                systemImage: "person.2"
            )
        }
    }

    /// Glyph, then the count between a minus and a plus with nothing else on
    /// that line, then the word for what is being counted.
    private func servingsStepper(
        _ scaling: Binding<RecipeScaling>
    ) -> some View {
        let value = scaling.wrappedValue
        // No stack spacing: the 44-point targets already hold seven points
        // of air either side of the circles drawn inside them.
        return VStack(spacing: 0) {
            glyph("person.2")
            HStack(spacing: LadleTheme.Spacing.tight) {
                // The arrows disable themselves at the ends of the range
                // instead of silently refusing, as a native stepper does.
                LadleIconButton(
                    systemImage: "minus",
                    accessibilityLabel: "Decrease servings",
                    tone: .onCard,
                    diameter: Self.stepDiameter
                ) {
                    step(scaling, by: -1)
                }
                .disabled(!value.canDecrease)

                Text(ladleNumber(value.servings))
                    .ladleFont(.recipeTitle)
                    .monospacedDigit()
                    .foregroundStyle(LadleTheme.Label.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minWidth: Self.countMinWidth)

                LadleIconButton(
                    systemImage: "plus",
                    accessibilityLabel: "Increase servings",
                    tone: .onCard,
                    diameter: Self.stepDiameter
                ) {
                    step(scaling, by: 1)
                }
                .disabled(!value.canIncrease)
            }
            // One adjustable element, the way VoiceOver meets a stepper:
            // swipe up or down on "Servings" rather than hunting for two
            // unlabelled-looking buttons either side of a number.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Servings")
            .accessibilityValue(yieldAccessibilityValue(value))
            .accessibilityHint("Scales the ingredient amounts")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(scaling, by: 1)
                case .decrement: step(scaling, by: -1)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("recipe.servings")

            servingsLabelRow(scaling)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, LadleTheme.Spacing.compact)
        .padding(.vertical, usesVerticalLayout ? LadleTheme.Spacing.medium : 0)
        .onDisappear { announcement?.cancel() }
    }

    /// What is being counted and, once the cook has changed it, the way
    /// back. One line of metadata in both states, so the band does not move
    /// when Reset arrives or leaves.
    private func servingsLabelRow(
        _ scaling: Binding<RecipeScaling>
    ) -> some View {
        let value = scaling.wrappedValue
        let grow = LadleTheme.Spacing.regular
        return HStack(spacing: LadleTheme.Spacing.tight) {
            // Hidden from VoiceOver: the stepper's value already says it.
            Text(servingsLabel(value))
                .accessibilityHidden(true)
            if value.isScaled {
                Text("·")
                    .accessibilityHidden(true)
                Button {
                    scaling.wrappedValue.reset()
                    announceOnceSettled(scaling.wrappedValue)
                } label: {
                    Text("Reset")
                        .foregroundStyle(accent.label)
                        // A line of metadata is 18 points tall and a target
                        // is 44. It grows sideways and down, into the band's
                        // own padding — never up, where it would take the
                        // presses meant for the plus above it.
                        .contentShape(
                            Rectangle().inset(by: -grow).offset(y: grow)
                        )
                }
                .buttonStyle(LadlePressButtonStyle())
                .accessibilityLabel("Reset to \(value.baseYieldText)")
                .accessibilityIdentifier("recipe.servings.reset")
            }
        }
        .ladleFont(.metadata)
        .foregroundStyle(LadleTheme.Label.secondary)
        .multilineTextAlignment(.center)
    }

    /// The word under the count. At the recipe's own yield it carries the
    /// hedge `ladleYieldText` would have; the reason is in the estimates
    /// note. Scaled, the count is the cook's choice and there is nothing to
    /// hedge.
    private func servingsLabel(_ scaling: RecipeScaling) -> String {
        let noun = scaling.servings == 1 ? "serving" : "servings"
        guard !scaling.isScaled, recipe.isYieldEstimated else { return noun }
        return recipe.servings == 1 ? "Yield unknown" : "\(noun), estimated"
    }

    private func step(_ scaling: Binding<RecipeScaling>, by count: Int) {
        let before = scaling.wrappedValue
        scaling.wrappedValue.step(by: count)
        guard scaling.wrappedValue != before else { return }
        announceOnceSettled(scaling.wrappedValue)
    }

    /// The phrase is built from the counts rather than `ladleYieldText`,
    /// which hedges an uncertain yield with "About" and reads as "scaled
    /// from Yield unknown".
    private func yieldAccessibilityValue(_ scaling: RecipeScaling) -> String {
        scaling.isScaled
            ? "\(scaling.chosenYieldText), scaled from \(scaling.baseYieldText)"
            : recipe.ladleYieldText
    }

    /// Spoken once the count settles, not on every step: the control reads
    /// its own value as it changes, and a cook stepping four to eight would
    /// otherwise hear each count twice. What VoiceOver needs is what the
    /// page settled on, and that the ingredients followed it.
    private func announceOnceSettled(_ scaling: RecipeScaling) {
        announcement?.cancel()
        announcement = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            AccessibilityNotification.Announcement(
                scaling.isScaled
                    ? "Scaled to \(scaling.chosenYieldText). Ingredient amounts updated."
                    : "Back to the recipe as written."
            )
            .post()
        }
    }

    private func metadataItem(
        value: String,
        label: String,
        systemImage: String
    ) -> some View {
        VStack(spacing: LadleTheme.Spacing.compact) {
            glyph(systemImage)
            Text(value)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.Label.primary)
                .lineLimit(usesVerticalLayout ? 2 : 1)
                .minimumScaleFactor(usesVerticalLayout ? 1 : 0.78)
            Text(label)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, LadleTheme.Spacing.compact)
        .padding(.vertical, usesVerticalLayout ? LadleTheme.Spacing.medium : 0)
        .accessibilityElement(children: .combine)
    }

    private func glyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: LadleTheme.IconSize.small, weight: .semibold))
            .foregroundStyle(accent.label)
            .accessibilityHidden(true)
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

    /// Whether the yield is the pipeline's estimate rather than a count the
    /// creator stated.
    var isYieldEstimated: Bool {
        uncertainties.contains { $0.field == "servings" }
    }

    var ladleYieldText: String {
        let value = ladleNumber(servings)
        let noun = servings == 1 ? "serving" : "servings"
        if isYieldEstimated {
            return servings == 1 ? "Yield unknown" : "About \(value) \(noun)"
        }
        return "\(value) \(noun)"
    }
}
