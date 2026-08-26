import LadleCore
import SwiftUI

struct MethodList: View {
    let steps: [RecipeStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LadleSectionHeader(
                title: "Method",
                detail: countText(steps.count, "step")
            )
            .padding(.bottom, LadleTheme.Layout.rowGap)

            ForEach(Array(steps.enumerated()), id: \.element.id) {
                index,
                step in
                HStack(alignment: .top, spacing: LadleTheme.Layout.iconGap) {
                    Text("\(index + 1)")
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.Label.onAccent)
                        .frame(width: 30, height: 30)
                        .background(LadleTheme.Intent.accent, in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: LadleTheme.Layout.rowGap) {
                        Text(step.instruction)
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.Label.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !step.timers.isEmpty {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    timerPills(for: step)
                                }

                                VStack(alignment: .leading, spacing: 8) {
                                    timerPills(for: step)
                                }
                            }
                        }

                        if let uncertainty = step.uncertainty {
                            Label(
                                uncertainty.reason,
                                systemImage: "exclamationmark.circle"
                            )
                            .ladleFont(.metadata)
                            .foregroundStyle(LadleTheme.Label.accent)
                            .accessibilityLabel(
                                "Uncertain step: \(uncertainty.reason)"
                            )
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }

    @ViewBuilder
    private func timerPills(for step: RecipeStep) -> some View {
        ForEach(step.timers) { timer in
            LadlePill(
                text: timer.detailText,
                systemImage: "timer",
                tint: LadleTheme.Surface.steel
            )
            .accessibilityLabel(
                "\(timer.label), \(timer.detailText)"
            )
        }
    }
}

private extension DetectedTimer {
    var detailText: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        if seconds == 0 {
            return "\(minutes) min"
        }
        return "\(minutes) min \(seconds) sec"
    }
}
