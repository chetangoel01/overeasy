import LadleCore
import SwiftUI

struct FocusModeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var viewModel: CookingViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 0) {
                focusHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        currentStepSection
                        timerSection
                        relevantIngredientsSection
                    }
                    .padding(.horizontal, LadleTheme.Spacing.generous)
                    .padding(.top, 24)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)

                navigationControls
            }
        }
        .background(LadleTheme.plum)
        .contentShape(Rectangle())
        .accessibilityIdentifier("cooking.focus-mode")
        .simultaneousGesture(
            DragGesture(minimumDistance: 44)
                .onEnded { value in
                    if value.translation.width < -44 {
                        advance()
                    } else if value.translation.width > 44 {
                        viewModel.movePrevious()
                    }
                }
        )
    }

    private var focusHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Button {
                    viewModel.exitFocusMode()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(LadleTheme.onAccent)
                        .frame(width: 44, height: 44)
                        .background(
                            LadleTheme.onAccent.opacity(0.1),
                            in: Circle()
                        )
                }
                .accessibilityLabel("Back to full recipe")

                Spacer()

                Text(viewModel.progressText)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.onAccent.opacity(0.82))
            }

            ProgressView(value: viewModel.progress)
                .tint(LadleTheme.focusAccent)
                .accessibilityLabel(
                    "\(viewModel.progressText) cooking progress"
                )
        }
        .padding(.horizontal, LadleTheme.Spacing.generous)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var currentStepSection: some View {
        if let step = viewModel.currentStep {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    viewModel.finishedTimerForCurrentStep == nil
                        ? "Step \(viewModel.currentStepIndex + 1)"
                        : "Timer finished"
                )
                .ladleFont(.eyebrow)
                .foregroundStyle(LadleTheme.focusAccent)

                Text(
                    viewModel.finishedTimerForCurrentStep.map {
                        "\($0.label) is ready."
                    } ?? step.instruction
                )
                    .ladleScaledFont(
                        size: 36,
                        relativeTo: .largeTitle,
                        weight: .semibold
                    )
                    .foregroundStyle(LadleTheme.onAccent)
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
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.onAccent)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(
                    LadleTheme.onAccent.opacity(0.1),
                    in: Capsule()
                )
                .buttonStyle(LadlePressButtonStyle())
                .sensoryFeedback(
                    .success,
                    trigger: viewModel.isStepCompleted(step.id)
                ) { wasComplete, isComplete in
                    LadleFeedbackPolicy.didComplete(
                        from: wasComplete,
                        to: isComplete
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var relevantIngredientsSection: some View {
        if !viewModel.relevantIngredients.isEmpty {
            Text(
                "For this step · "
                    + viewModel.relevantIngredients
                    .map(\.name)
                    .joined(separator: " · ")
            )
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.onAccent.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var timerSection: some View {
        if let step = viewModel.currentStep,
           !step.timers.isEmpty {
            ForEach(step.timers) { timer in
                RecipeTimerButton(
                    viewModel: viewModel,
                    detectedTimer: timer,
                    onDark: true
                )
            }
        }
    }

    private var navigationControls: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.movePrevious()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(LadleTheme.onAccent)
                    .frame(width: 52, height: 52)
                    .background(
                        LadleTheme.onAccent.opacity(0.1),
                        in: Circle()
                    )
            }
            .buttonStyle(LadlePressButtonStyle())
            .disabled(!viewModel.canMovePrevious)
            .accessibilityLabel("Previous step")

            Button(action: advance) {
                Text(nextButtonTitle)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(
                        LadleTheme.focusAccent,
                        in: RoundedRectangle(
                            cornerRadius: LadleTheme.Corner.control,
                            style: .continuous
                        )
                    )
            }
            .buttonStyle(LadlePressButtonStyle())
            .accessibilityLabel(nextButtonTitle)
        }
        .padding(.horizontal, LadleTheme.Spacing.regular)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(LadleTheme.plum)
    }

    private var nextButtonTitle: String {
        if viewModel.finishedTimerForCurrentStep != nil {
            "Continue cooking"
        } else if viewModel.canMoveNext {
            "Next step"
        } else {
            "Back to full recipe"
        }
    }

    private func advance() {
        if viewModel.canMoveNext {
            viewModel.moveNext()
        } else {
            viewModel.exitFocusMode()
        }
    }
}
