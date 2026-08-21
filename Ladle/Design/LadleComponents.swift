import SwiftUI

enum LadlePressKind {
    case card
    case control

    var scale: CGFloat {
        switch self {
        case .card:
            0.97
        case .control:
            0.94
        }
    }

    var duration: TimeInterval {
        switch self {
        case .card:
            0.18
        case .control:
            0.15
        }
    }
}

enum LadleTimerFeedback: Equatable {
    case started
    case paused
    case finished
}

enum LadleFeedbackPolicy {
    static func didPush(from oldCount: Int, to newCount: Int) -> Bool {
        newCount > oldCount
    }

    static func didComplete(from wasComplete: Bool, to isComplete: Bool)
        -> Bool {
        !wasComplete && isComplete
    }

    static func didFinishReview(
        wasPending: Bool,
        isPending: Bool
    ) -> Bool {
        wasPending && !isPending
    }

    static func timerFeedback(
        from oldPhase: RecipeTimerPhase,
        to newPhase: RecipeTimerPhase
    ) -> LadleTimerFeedback? {
        guard oldPhase != newPhase else {
            return nil
        }
        switch newPhase {
        case .idle:
            return nil
        case .running:
            return .started
        case .paused:
            return .paused
        case .finished:
            return .finished
        }
    }
}

struct LadlePressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var kind: LadlePressKind = .control

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                reduceMotion || !isEnabled
                    ? 1
                    : (configuration.isPressed ? kind.scale : 1)
            )
            .opacity(
                !isEnabled
                    ? 0.48
                    : (configuration.isPressed ? 0.86 : 1)
            )
            .animation(
                reduceMotion
                    ? nil
                    : .snappy(
                        duration: kind.duration,
                        extraBounce: 0
                    ),
                value: configuration.isPressed
            )
    }
}

struct LadlePrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .ladleFont(.bodyStrong)
            .foregroundStyle(
                isProminent ? LadleTheme.onAccent : LadleTheme.ink
            )
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                isProminent ? LadleTheme.brick : LadleTheme.oat,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
            .opacity(
                !isEnabled
                    ? 0.48
                    : (configuration.isPressed ? 0.86 : 1)
            )
            .scaleEffect(
                reduceMotion || !isEnabled
                    ? 1
                    : (configuration.isPressed ? 0.97 : 1)
            )
            .animation(
                reduceMotion
                    ? nil
                    : .snappy(duration: 0.18, extraBounce: 0),
                value: configuration.isPressed
            )
    }
}

struct LadlePill: View {
    let text: String
    var systemImage: String?
    var tint = LadleTheme.field
    var foreground = LadleTheme.ink

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .ladleFont(.metadata)
            .foregroundStyle(foreground)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(tint, in: Capsule())
    }
}

struct LadleSectionHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    var detail: String?

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    titleLabel
                    detailLabel
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    titleLabel
                    Spacer()
                    detailLabel
                }
            }
        }
        .foregroundStyle(LadleTheme.ink)
        .accessibilityElement(children: .combine)
    }

    private var titleLabel: some View {
        Text(title)
            .ladleFont(.section)
    }

    @ViewBuilder
    private var detailLabel: some View {
        if let detail {
            Text(detail)
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.mutedInk)
        }
    }
}

struct EstimateLabel: View {
    var body: some View {
        Label("Estimated", systemImage: "info.circle")
            .ladleFont(.metadata)
            .foregroundStyle(LadleTheme.ink.opacity(0.62))
            .accessibilityHint(
                "Nutrition and uncertain imported values may be estimates."
            )
    }
}

struct LadleSheetHandle: View {
    var body: some View {
        Capsule()
            .fill(LadleTheme.ink.opacity(0.18))
            .frame(width: 42, height: 5)
            .accessibilityHidden(true)
    }
}

enum LadleIconButtonTone {
    case quiet
    case primary
    case onDark

    var background: Color {
        switch self {
        case .quiet:
            LadleTheme.ube
        case .primary:
            LadleTheme.brick
        case .onDark:
            LadleTheme.onAccent.opacity(0.12)
        }
    }

    var foreground: Color {
        switch self {
        case .quiet:
            LadleTheme.ink
        case .primary:
            LadleTheme.onAccent
        case .onDark:
            LadleTheme.onAccent
        }
    }
}

struct LadleIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var tone: LadleIconButtonTone = .quiet
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tone.foreground)
                .frame(width: 44, height: 44)
                .background(tone.background, in: Circle())
        }
        .buttonStyle(LadlePressButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

struct LadleStateView: View {
    enum Tone {
        case neutral
        case success
        case warning

        var background: Color {
            switch self {
            case .neutral, .warning:
                LadleTheme.ube
            case .success:
                LadleTheme.celery
            }
        }
    }

    let systemImage: String
    let title: String
    let message: String
    var tone: Tone = .neutral
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: LadleTheme.Spacing.regular) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(LadleTheme.ink)
                .frame(width: 60, height: 60)
                .background(tone.background, in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: LadleTheme.Spacing.compact) {
                Text(title)
                    .ladleFont(.title)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(LadleTheme.ink)

                Text(message)
                    .ladleFont(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(LadleTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let primaryTitle, let primaryAction {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(LadlePrimaryButtonStyle())
            }

            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(
                        LadlePrimaryButtonStyle(isProminent: false)
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(LadleTheme.Spacing.generous)
        .accessibilityElement(children: .contain)
    }
}

private struct LadleCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                LadleTheme.oat,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
            )
    }
}

extension View {
    func ladleCard() -> some View {
        modifier(LadleCardModifier())
    }
}

func countText(_ count: Int, _ noun: String) -> String {
    count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
}
