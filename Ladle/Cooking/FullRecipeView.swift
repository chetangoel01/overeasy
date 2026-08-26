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
                ? LadleTheme.Surface.graphite
                : LadleTheme.Surface.porcelain)
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
                VStack(alignment: .leading, spacing: LadleTheme.Layout.sectionGap) {
                    recipeHeader
                    cookingControls
                    ingredientsSection
                    methodSection
                }
                .padding(.horizontal, LadleTheme.Spacing.generous)
                .padding(.bottom, LadleTheme.Layout.scrollTail)
            }
            .scrollIndicators(.hidden)
            .background(LadleTheme.Surface.porcelain)
            .accessibilityIdentifier("cooking.full-recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(LadleTheme.Surface.porcelain, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(LadleTheme.Label.primary)
                            .frame(width: 44, height: 44)
                            .background(LadleTheme.Surface.steel, in: Circle())
                    }
                    .accessibilityLabel("Close cooking")
                }
            }
        }
    }

    private var recipeHeader: some View {
        Text(viewModel.recipe.title)
            .ladleFont(.title)
            .foregroundStyle(LadleTheme.Label.primary)
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
            .foregroundStyle(LadleTheme.Label.primary)
            .tint(LadleTheme.Label.accent)
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .background(
                LadleTheme.Surface.raised,
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
                .foregroundStyle(LadleTheme.Label.onAccent)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(LadleTheme.Intent.accent, in: Capsule())
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
                            .overlay(LadleTheme.Label.primary.opacity(0.08))
                            .padding(
                                .leading,
                                LadleTheme.dividerInset(
                                    iconWidth: Self.completionIconWidth
                                )
                            )
                    }
                }
            }
            .padding(.horizontal, LadleTheme.Layout.cardPadding)
            .background(
                LadleTheme.Surface.raised,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
            )
        }
    }

    private var methodSection: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Layout.rowGap) {
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
            HStack(spacing: LadleTheme.Layout.iconGap) {
                completionIcon(isCompleted: isCompleted)
                Text(ingredient.cookingDetailText)
                    .ladleFont(.body)
                    .foregroundStyle(
                        LadleTheme.Label.primary.opacity(isCompleted ? 0.48 : 1)
                    )
                    .strikethrough(isCompleted)
                Spacer(minLength: 0)
            }
            .padding(.vertical, LadleTheme.Spacing.medium)
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

        return VStack(alignment: .leading, spacing: LadleTheme.Layout.rowGap) {
            Button {
                viewModel.toggleCompletedStep(step.id)
            } label: {
                HStack(alignment: .top, spacing: LadleTheme.Layout.iconGap) {
                    completionIcon(
                        isCompleted: isCompleted,
                        number: index + 1
                    )
                    Text(step.instruction)
                        .ladleFont(.recipeTitle)
                        .foregroundStyle(
                            LadleTheme.Label.primary.opacity(
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
            isCurrent ? LadleTheme.Surface.steel : LadleTheme.Surface.raised,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.card,
                style: .continuous
            )
        )
    }

    /// Width of the tick or step number leading each checklist row. The
    /// row dividers derive their inset from this so they cannot drift
    /// away from the labels they separate.
    private static let completionIconWidth: CGFloat = 30

    private func completionIcon(
        isCompleted: Bool,
        number: Int? = nil
    ) -> some View {
        ZStack {
            Circle()
                .fill(
                    isCompleted ? LadleTheme.Intent.success : Color.clear
                )
                .overlay {
                    Circle()
                        .stroke(
                            isCompleted
                                ? LadleTheme.Intent.success
                                : LadleTheme.Label.primary.opacity(0.24),
                            lineWidth: 1.5
                        )
                }

            if isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(LadleTheme.Label.primary)
            } else if let number {
                Text("\(number)")
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.primary.opacity(0.58))
            }
        }
        .frame(
            width: Self.completionIconWidth,
            height: Self.completionIconWidth
        )
        .accessibilityHidden(true)
    }
}
