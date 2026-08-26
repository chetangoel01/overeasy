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
            .padding(.bottom, 14)

            ForEach(Array(steps.enumerated()), id: \.element.id) {
                index,
                step in
                HStack(alignment: .top, spacing: 14) {
                    Text("\(index + 1)")
                        .ladleFont(.metadata)
                        .foregroundStyle(LadleTheme.onAccent)
                        .frame(width: 30, height: 30)
                        .background(LadleTheme.brick, in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(step.instruction)
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.ink)
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
                            .foregroundStyle(LadleTheme.paprika)
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
