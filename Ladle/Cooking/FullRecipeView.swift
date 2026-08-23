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
        .background(
            (viewModel.mode == .focus
                ? LadleTheme.plum
                : LadleTheme.paper)
                .ignoresSafeArea()
        )
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
                .padding(.horizontal, LadleTheme.Spacing.generous)
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
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(LadleTheme.ink)
                            .frame(width: 44, height: 44)
                            .background(LadleTheme.ube, in: Circle())
                    }
                    .accessibilityLabel("Close cooking")
                }
            }
        }
    }

    private var recipeHeader: some View {
        Text(viewModel.recipe.title)
            .ladleFont(.title)
            .foregroundStyle(LadleTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
    }

    private var cookingControls: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    progressControl
                    focusModeButton
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 12) {
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
        Menu {
            ForEach(
                Array(viewModel.recipe.orderedSteps.indices),
                id: \.self
            ) { index in
                Button("Step \(index + 1)") {
                    viewModel.selectStep(at: index)
                }
            }
        } label: {
            LadlePill(
                text: viewModel.progressText,
                systemImage: "chevron.down"
            )
            .frame(minHeight: 44)
        }
        .accessibilityLabel("\(viewModel.progressText) cooking progress")
    }

    private var focusModeButton: some View {
        Button {
            viewModel.enterFocusMode()
        } label: {
            Label("Focus mode", systemImage: "rectangle.expand.vertical")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.onAccent)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(LadleTheme.brick, in: Capsule())
        }
        .buttonStyle(LadlePressButtonStyle())
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(title: "Ingredients")

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
            LadleSectionHeader(title: "Method")

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
        .buttonStyle(LadlePressButtonStyle())
        .sensoryFeedback(.success, trigger: isCompleted) {
            wasComplete,
            isComplete in
            LadleFeedbackPolicy.didComplete(
                from: wasComplete,
                to: isComplete
            )
        }
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
            .buttonStyle(LadlePressButtonStyle())
            .sensoryFeedback(.success, trigger: isCompleted) {
                wasComplete,
                isComplete in
                LadleFeedbackPolicy.didComplete(
                    from: wasComplete,
                    to: isComplete
                )
            }
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
                    .foregroundStyle(LadleTheme.ink)
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
