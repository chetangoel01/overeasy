import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LadleTimersBundle: WidgetBundle {
    var body: some Widget {
        CookingTimerLiveActivity()
    }
}

/// A running cooking timer on the Lock Screen, in the banner, and in the
/// Dynamic Island. The app is suspended for most of a timer's life, so every
/// appearance is drawn from dates the system can advance on its own.
struct CookingTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(
            for: CookingTimerActivityAttributes.self
        ) { context in
            CookingTimerLockScreenView(
                attributes: context.attributes,
                appearance: CookingTimerAppearance(context: context)
            )
            .widgetURL(context.attributes.stepURL)
            .activityBackgroundTint(TimerActivityPalette.background)
            .activitySystemActionForegroundColor(TimerActivityPalette.label)
        } dynamicIsland: { context in
            let appearance = CookingTimerAppearance(context: context)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.label)
                        .ladleTimerFont(.headline)
                        .foregroundStyle(TimerActivityPalette.label)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CookingTimerCountdown(appearance: appearance)
                        .ladleTimerFont(.title3)
                        .foregroundStyle(TimerActivityPalette.label)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.attributes.recipeTitle)
                            .ladleTimerFont(.footnote)
                            .foregroundStyle(
                                TimerActivityPalette.secondaryLabel
                            )
                            .lineLimit(1)
                        CookingTimerProgressBar(
                            appearance: appearance,
                            durationSeconds:
                                context.attributes.durationSeconds
                        )
                    }
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(TimerActivityPalette.signal)
            } compactTrailing: {
                CookingTimerCountdown(appearance: appearance)
                    .foregroundStyle(TimerActivityPalette.label)
                    // A `Text(timerInterval:)` asks for all the width it is
                    // offered, and the compact island grants it: the digits
                    // sat at the far right of a pill stretched across the
                    // notch with nothing between them and the glyph. A fixed
                    // column just wide enough for the longest string this
                    // timer can show keeps the pill as tight as the system's
                    // own timers.
                    .frame(
                        width: CookingTimerCountdown.compactWidth(
                            durationSeconds: context.attributes.durationSeconds
                        ),
                        alignment: .trailing
                    )
            } minimal: {
                CookingTimerCountdown(appearance: appearance)
                    // The minimal slot is barely wider than the glyph it
                    // usually holds, and the countdown truncated to "0:..."
                    // at the compact size.
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(TimerActivityPalette.label)
            }
            .widgetURL(context.attributes.stepURL)
            .keylineTint(TimerActivityPalette.signal)
        }
        // The watch Smart Stack, which shows the timer on a wrist while the
        // phone stays face-up on the counter.
        .supplementalActivityFamilies([.small])
    }
}

extension CookingTimerAppearance {
    init(context: ActivityViewContext<CookingTimerActivityAttributes>) {
        self.init(state: context.state, isStale: context.isStale)
    }
}

/// The countdown, which is the state: nothing purely visual carries it, so a
/// cook reading the screen and a cook hearing it get the same answer.
struct CookingTimerCountdown: View {
    let appearance: CookingTimerAppearance

    var body: some View {
        Group {
            switch appearance {
            case let .running(deadline):
                Text(timerInterval: Date.now...deadline, countsDown: true)
                    .multilineTextAlignment(.trailing)
            case let .paused(remainingSeconds):
                Text(CookingTimerClock.text(for: remainingSeconds))
            case .finished:
                Text("Done")
            }
        }
        .monospacedDigit()
    }

    /// The compact island's column for the countdown: `m:ss` needs one width,
    /// and a timer that starts past an hour shows `h:mm:ss` until it drops
    /// under, so it is sized for the longest string it will ever hold and the
    /// pill never resizes as the digits change.
    static func compactWidth(durationSeconds: Int) -> CGFloat {
        durationSeconds >= 3_600 ? 64 : 46
    }
}

/// The bar fills as the timer runs down, so a glance at how far it has come
/// answers without reading the digits. It is full at the finish; the in-app
/// ring drains instead, because there the ring is the button's own glyph.
struct CookingTimerProgressBar: View {
    let appearance: CookingTimerAppearance
    let durationSeconds: Int

    var body: some View {
        Group {
            switch appearance {
            case let .running(deadline):
                ProgressView(
                    timerInterval: elapsedInterval(to: deadline),
                    countsDown: false
                ) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            case let .paused(remainingSeconds):
                ProgressView(
                    value: max(duration - Double(remainingSeconds), 0),
                    total: duration
                )
            case .finished:
                ProgressView(value: 1)
            }
        }
        .progressViewStyle(.linear)
        .tint(TimerActivityPalette.signal)
        // The countdown beside it already says the same thing, and says it
        // in words.
        .accessibilityHidden(true)
    }

    private var duration: Double {
        Double(max(durationSeconds, 1))
    }

    /// The deadline, back-dated by the whole duration, so a resumed timer
    /// picks the bar up where the pause left it rather than restarting it.
    private func elapsedInterval(to deadline: Date) -> ClosedRange<Date> {
        deadline.addingTimeInterval(-duration)...deadline
    }
}

/// The Lock Screen and banner presentation, and — at `.small` — the watch
/// Smart Stack's, which drops the recipe title a wrist has no room for.
struct CookingTimerLockScreenView: View {
    @Environment(\.activityFamily) private var activityFamily

    /// Room for an hour-long timer's "1:00:00", and it grows with the text.
    @ScaledMetric(relativeTo: .title2) private var countdownWidth: CGFloat = 104

    let attributes: CookingTimerActivityAttributes
    let appearance: CookingTimerAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributes.label)
                        .ladleTimerFont(.headline)
                        .foregroundStyle(TimerActivityPalette.label)
                        .lineLimit(1)

                    if !isCompact {
                        Text(attributes.recipeTitle)
                            .ladleTimerFont(.subheadline)
                            .foregroundStyle(
                                TimerActivityPalette.secondaryLabel
                            )
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(headerAccessibilityLabel)

                CookingTimerCountdown(appearance: appearance)
                    .ladleTimerFont(isCompact ? .headline : .title2)
                    .foregroundStyle(TimerActivityPalette.label)
                    // A column of its own, so the digits do not shuffle the
                    // title sideways as they change, and the title gets the
                    // rest of the card instead of half of it. `fixedSize`
                    // would do the first of those, but a Lock Screen view
                    // that sizes itself that way is refused outright and the
                    // card never draws.
                    .frame(width: countdownWidth, alignment: .trailing)
            }

            CookingTimerProgressBar(
                appearance: appearance,
                durationSeconds: attributes.durationSeconds
            )
        }
        .padding(.horizontal, isCompact ? 12 : 16)
        .padding(.vertical, isCompact ? 10 : 14)
    }

    private var isCompact: Bool {
        activityFamily == .small
    }

    private var headerAccessibilityLabel: String {
        "\(attributes.label), step \(attributes.stepIndex + 1) of "
            + attributes.recipeTitle
    }
}

private extension View {
    /// Dynamic Type, with the weight the app gives the same roles. A Live
    /// Activity has no `LadleTypography`, and a fixed point size here would
    /// stop growing for a cook who sizes text up.
    func ladleTimerFont(_ style: Font.TextStyle) -> some View {
        font(.system(style, design: .default, weight: .semibold))
    }
}
