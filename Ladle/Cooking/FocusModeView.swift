import LadleCore
import SwiftUI

/// Classifies a completed Focus Mode drag as a step change. A drag counts
/// only when it is predominantly horizontal and travelled far enough on
/// that axis, so vertically scrolling long step content — however much it
/// drifts sideways — never changes the step or exits Focus Mode.
enum FocusModeSwipe {
    case nextStep
    case previousStep

    /// The horizontal travel below which a drag never reads as a swipe.
    static let minimumTravel: CGFloat = 44

    init?(translation: CGSize) {
        guard abs(translation.width) > Self.minimumTravel,
              abs(translation.width) > abs(translation.height) else {
            return nil
        }
        self = translation.width < 0 ? .nextStep : .previousStep
    }
}

struct FocusModeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var viewModel: CookingViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 0) {
                focusHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: LadleTheme.Layout.sectionGap) {
                        currentStepSection
                        timerSection
                        relevantIngredientsSection
                    }
                    // Fill the width, or the stack shrinks to its widest child
                    // and the scroll view centres it — so a short instruction
                    // sat further in from the edge than a long one, and the
                    // margin visibly jumped from step to step.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LadleTheme.Spacing.generous)
                    .padding(.top, 24)
                    .padding(.bottom, LadleTheme.Layout.scrollTail)
                }
                .scrollIndicators(.hidden)

                navigationControls
            }
        }
        .background(LadleTheme.Surface.graphite)
        .contentShape(Rectangle())
        .accessibilityIdentifier("cooking.focus-mode")
        .simultaneousGesture(
            DragGesture(minimumDistance: FocusModeSwipe.minimumTravel)
                .onEnded { value in
                    switch FocusModeSwipe(translation: value.translation) {
                    case .nextStep:
                        advance()
                    case .previousStep:
                        viewModel.movePrevious()
                    case nil:
                        break
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
                        .font(.system(size: LadleTheme.IconSize.medium, weight: .semibold))
                        .foregroundStyle(LadleTheme.Label.onAccent)
                        .frame(width: LadleTheme.Control.hitTarget, height: LadleTheme.Control.hitTarget)
                        .background(
                            LadleTheme.Label.onAccent.opacity(0.1),
                            in: Circle()
                        )
                }
                .accessibilityLabel("Back to full recipe")

                Spacer()

                Text(viewModel.progressText)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.onAccent.opacity(0.82))
            }

            ProgressView(value: viewModel.progress)
                .tint(LadleTheme.Intent.focus)
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
                .foregroundStyle(LadleTheme.Intent.focus)

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
                    .foregroundStyle(LadleTheme.Label.onAccent)
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
                .foregroundStyle(LadleTheme.Label.onAccent)
                .padding(.horizontal, 12)
                .frame(minHeight: LadleTheme.Control.hitTarget)
                .background(
                    LadleTheme.Label.onAccent.opacity(0.1),
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
            .foregroundStyle(LadleTheme.Label.onAccent.opacity(0.8))
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
                    .font(.system(size: LadleTheme.IconSize.medium, weight: .bold))
                    .foregroundStyle(LadleTheme.Label.onAccent)
                    .frame(
                        width: LadleTheme.Control.primary,
                        height: LadleTheme.Control.primary
                    )
                    .background(
                        LadleTheme.Label.onAccent.opacity(0.1),
                        in: Circle()
                    )
            }
            .buttonStyle(LadlePressButtonStyle())
            .disabled(!viewModel.canMovePrevious)
            .accessibilityLabel("Previous step")

            Button(action: advance) {
                Text(nextButtonTitle)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(LadleTheme.Label.onAccent)
                    .frame(maxWidth: .infinity, minHeight: LadleTheme.Control.primary)
                    .background(
                        LadleTheme.Intent.focus,
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
        .padding(.bottom, LadleTheme.Spacing.medium)
        .background(LadleTheme.Surface.graphite)
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
