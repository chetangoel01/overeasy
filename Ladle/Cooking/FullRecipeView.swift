import LadleCore
import SwiftUI

struct FullRecipeView: View {
    @Environment(\.dismiss) private var dismiss

    @Bindable var viewModel: CookingViewModel

    var body: some View {
        Group {
            if viewModel.mode == .focus {
                FocusModeView(viewModel: viewModel)
            } else {
                fullRecipeContent
            }
        }
        .background(LadleTheme.paper)
        .onAppear {
            viewModel.beginCooking()
        }
        .onDisappear {
            viewModel.endCooking()
        }
    }

    private var fullRecipeContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    recipeHeader
                    cookingControls
                    ingredientsSection
                    methodSection
                }
                .padding(.horizontal, LadleTheme.Spacing.regular)
                .padding(.bottom, 48)
            }
            .scrollIndicators(.hidden)
            .background(LadleTheme.paper)
            .accessibilityIdentifier("cooking.full-recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(LadleTheme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .accessibilityLabel("Close cooking")
                }
                ToolbarItem(placement: .principal) {
                    Text("Cooking")
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.ink.opacity(0.62))
                }
            }
        }
    }

    private var recipeHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Full recipe")
                .textCase(.uppercase)
                .ladleFont(.eyebrow)
                .tracking(1.5)
                .foregroundStyle(LadleTheme.paprika)
                .padding(.top, 12)
                .accessibilityLabel("Full recipe")

            Text(viewModel.recipe.title)
                .ladleFont(.title)
                .foregroundStyle(LadleTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                "\(viewModel.recipe.orderedIngredients.count) ingredients · \(viewModel.recipe.orderedSteps.count) steps"
            )
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.ink.opacity(0.58))
        }
    }

    private var cookingControls: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    progressControl
                    focusModeButton
                        .frame(maxWidth: 174)
                }

                VStack(spacing: 12) {
                    progressControl
                    focusModeButton
                }
            }

            Toggle(
                "Keep screen awake",
                isOn: Binding(
                    get: { viewModel.keepsScreenAwake },
                    set: { isEnabled in
                        viewModel.setKeepsScreenAwake(isEnabled)
                    }
                )
            )
            .ladleFont(.bodyStrong)
            .foregroundStyle(LadleTheme.ink)
            .tint(LadleTheme.paprika)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(
                LadleTheme.field,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
        }
    }

    private var progressControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.progressText)
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.ink)
            ProgressView(value: viewModel.progress)
                .tint(LadleTheme.paprika)
                .accessibilityLabel(
                    "\(viewModel.progressText) cooking progress"
                )
        }
    }

    private var focusModeButton: some View {
        Button {
            viewModel.enterFocusMode()
        } label: {
            Label("Focus mode", systemImage: "rectangle.expand.vertical")
        }
        .buttonStyle(LadlePrimaryButtonStyle())
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(
                title: "Ingredients",
                detail: "Tap as you prep"
            )

            VStack(spacing: 0) {
                ForEach(
                    Array(viewModel.recipe.orderedIngredients.enumerated()),
                    id: \.element.id
                ) { index, ingredient in
                    checkableIngredient(ingredient)

                    if index
                        < viewModel.recipe.orderedIngredients.count - 1 {
                        Divider()
                            .overlay(LadleTheme.ink.opacity(0.08))
                            .padding(.leading, 52)
                    }
                }
            }
            .padding(.horizontal, 14)
            .background(
                LadleTheme.field,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
            )
        }
    }

    private var methodSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LadleSectionHeader(
                title: "Method",
                detail: "\(viewModel.recipe.orderedSteps.count) steps"
            )

            ForEach(
                Array(viewModel.recipe.orderedSteps.enumerated()),
                id: \.element.id
            ) { index, step in
                methodCard(step: step, index: index)
            }
        }
    }

    private func checkableIngredient(
        _ ingredient: Ingredient
    ) -> some View {
        let isCompleted = viewModel.isIngredientCompleted(ingredient.id)

        return Button {
            viewModel.toggleCompletedIngredient(ingredient.id)
        } label: {
            HStack(spacing: 13) {
                completionIcon(isCompleted: isCompleted)
                Text(ingredient.cookingDetailText)
                    .ladleFont(.body)
                    .foregroundStyle(
                        LadleTheme.ink.opacity(isCompleted ? 0.48 : 1)
                    )
                    .strikethrough(isCompleted)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isCompleted
                ? "Mark \(ingredient.name) incomplete"
                : "Mark \(ingredient.name) complete"
        )
    }

    private func methodCard(
        step: RecipeStep,
        index: Int
    ) -> some View {
        let isCompleted = viewModel.isStepCompleted(step.id)
        let isCurrent = index == viewModel.currentStepIndex

        return VStack(alignment: .leading, spacing: 14) {
            Button {
                viewModel.toggleCompletedStep(step.id)
            } label: {
                HStack(alignment: .top, spacing: 13) {
                    completionIcon(
                        isCompleted: isCompleted,
                        number: index + 1
                    )
                    Text(step.instruction)
                        .ladleFont(.recipeTitle)
                        .foregroundStyle(
                            LadleTheme.ink.opacity(
                                isCompleted ? 0.48 : 1
                            )
                        )
                        .strikethrough(isCompleted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isCompleted
                    ? "Mark step \(index + 1) incomplete, \(step.instruction)"
                    : "Mark step \(index + 1) complete, \(step.instruction)"
            )

            ForEach(step.timers) { timer in
                RecipeTimerButton(
                    viewModel: viewModel,
                    detectedTimer: timer
                )
            }
        }
        .padding(16)
        .background(
            isCurrent ? LadleTheme.review : LadleTheme.field,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    private func completionIcon(
        isCompleted: Bool,
        number: Int? = nil
    ) -> some View {
        ZStack {
            Circle()
                .fill(
                    isCompleted ? LadleTheme.success : Color.clear
                )
                .overlay {
                    Circle()
                        .stroke(
                            isCompleted
                                ? LadleTheme.success
                                : LadleTheme.ink.opacity(0.24),
                            lineWidth: 1.5
                        )
                }

            if isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white)
            } else if let number {
                Text("\(number)")
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.ink.opacity(0.58))
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }
}

extension Ingredient {
    var cookingDetailText: String {
        var parts = [quantityText, unit]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        parts.append(name)
        if let preparation, !preparation.isEmpty {
            parts.append("— \(preparation)")
        }
        return parts.joined(separator: " ")
    }
}
