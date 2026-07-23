import LadleCore
import SwiftUI

struct FocusModeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var viewModel: CookingViewModel

    var body: some View {
        VStack(spacing: 0) {
            focusHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    progressSection
                    currentStepSection
                    relevantIngredientsSection
                    timerSection
                }
                .padding(.horizontal, LadleTheme.Spacing.generous)
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)

            navigationControls
        }
        .background(LadleTheme.paper)
        .contentShape(Rectangle())
        .accessibilityIdentifier("cooking.focus-mode")
        .simultaneousGesture(
            DragGesture(minimumDistance: 44)
                .onEnded { value in
                    if value.translation.width < -44 {
                        viewModel.moveNext()
                    } else if value.translation.width > 44 {
                        viewModel.movePrevious()
                    }
                }
        )
    }

    private var focusHeader: some View {
        HStack {
            Button {
                viewModel.exitFocusMode()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back to full recipe")

            Spacer()

            Text("Focus mode")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.ink.opacity(0.62))

            Spacer()

            Image(systemName: "flame.fill")
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .background(LadleTheme.paper)
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(LadleTheme.ink.opacity(0.08))
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(viewModel.progressText)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.paprika)
                Spacer()
                Text(viewModel.recipe.title)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.ink.opacity(0.5))
                    .lineLimit(1)
            }

            ProgressView(value: viewModel.progress)
                .tint(LadleTheme.paprika)
                .scaleEffect(x: 1, y: 1.8, anchor: .center)
                .accessibilityLabel(
                    "\(viewModel.progressText) cooking progress"
                )
        }
    }

    @ViewBuilder
    private var currentStepSection: some View {
        if let step = viewModel.currentStep {
            VStack(alignment: .leading, spacing: 16) {
                Text("DO THIS NOW")
                    .ladleFont(.eyebrow)
                    .tracking(1.6)
                    .foregroundStyle(LadleTheme.paprika)

                Text(step.instruction)
                    .ladleScaledFont(
                        size: 38,
                        relativeTo: .largeTitle,
                        weight: .medium,
                        design: .serif
                    )
                    .foregroundStyle(LadleTheme.ink)
                    .minimumScaleFactor(
                        dynamicTypeSize.isAccessibilitySize ? 1 : 0.72
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("focus.step.large")

                Button {
                    viewModel.toggleCompletedStep(step.id)
                } label: {
                    Label(
                        viewModel.isStepCompleted(step.id)
                            ? "Step complete"
                            : "Mark step complete",
                        systemImage:
                            viewModel.isStepCompleted(step.id)
                                ? "checkmark.circle.fill"
                                : "circle"
                    )
                }
                .buttonStyle(
                    LadlePrimaryButtonStyle(isProminent: false)
                )
            }
        }
    }

    @ViewBuilder
    private var relevantIngredientsSection: some View {
        if !viewModel.relevantIngredients.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                LadleSectionHeader(
                    title: "For this step",
                    detail:
                        "\(viewModel.relevantIngredients.count) ingredients"
                )

                VStack(spacing: 10) {
                    ForEach(viewModel.relevantIngredients) { ingredient in
                        let isCompleted = viewModel
                            .isIngredientCompleted(ingredient.id)

                        Button {
                            viewModel.toggleCompletedIngredient(
                                ingredient.id
                            )
                        } label: {
                            HStack(spacing: 12) {
                                Image(
                                    systemName:
                                        isCompleted
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                )
                                .foregroundStyle(
                                    isCompleted
                                        ? LadleTheme.success
                                        : LadleTheme.paprika
                                )
                                Text(ingredient.cookingDetailText)
                                    .ladleFont(.bodyStrong)
                                    .foregroundStyle(LadleTheme.ink)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 52)
                            .background(
                                LadleTheme.field,
                                in: RoundedRectangle(
                                    cornerRadius:
                                        LadleTheme.Corner.control,
                                    style: .continuous
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            isCompleted
                                ? "Mark \(ingredient.name) incomplete"
                                : "Mark \(ingredient.name) complete"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var timerSection: some View {
        if let step = viewModel.currentStep,
           !step.timers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                LadleSectionHeader(title: "Timers")
                ForEach(step.timers) { timer in
                    RecipeTimerButton(
                        viewModel: viewModel,
                        detectedTimer: timer
                    )
                }
            }
        }
    }

    private var navigationControls: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.movePrevious()
            } label: {
                Label("Previous", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LadlePrimaryButtonStyle(isProminent: false))
            .disabled(!viewModel.canMovePrevious)
            .accessibilityLabel("Previous step")

            Button {
                viewModel.moveNext()
            } label: {
                Label(
                    viewModel.canMoveNext ? "Next" : "Last step",
                    systemImage: "chevron.right"
                )
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LadlePrimaryButtonStyle())
            .disabled(!viewModel.canMoveNext)
            .accessibilityLabel("Next step")
        }
        .padding(.horizontal, LadleTheme.Spacing.regular)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
                .overlay(LadleTheme.ink.opacity(0.08))
        }
    }
}
