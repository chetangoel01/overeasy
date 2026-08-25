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

/// The four kinds of filled or textual button the app has. A button that is
/// none of these is a button that has not been designed: reach for the closest
/// role rather than assembling a new one out of a background and a font.
///
/// Icon-only controls are not roles here — they are `LadleIconButton`.
enum LadleButtonRole {
    /// The one action the screen exists to perform.
    case primary
    /// A real alternative to the primary action, shown beside it.
    case secondary
    /// Deletes or discards. Uses the system destructive colour so it matches
    /// the platform's own delete affordances.
    case destructive
    /// A low-commitment action, often an escape. No fill.
    case tertiary

    /// `nil` draws no fill at all.
    var fill: Color? {
        switch self {
        case .primary:
            LadleTheme.Intent.accent
        case .secondary:
            LadleTheme.Surface.raised
        case .destructive:
            LadleTheme.Intent.destructive
        case .tertiary:
            nil
        }
    }

    var label: Color {
        switch self {
        case .primary, .destructive:
            LadleTheme.Label.onAccent
        case .secondary:
            LadleTheme.Label.primary
        case .tertiary:
            LadleTheme.Label.accent
        }
    }
}

/// Every filled or textual button in the app.
///
/// Disabled controls drop their fill colour entirely rather than wearing a
/// faded version of it: a washed-out accent still reads as an accent button,
/// and at the opacity that made it look disabled its label fell below three
/// to one against the fill.
struct LadleButtonStyle: ButtonStyle {
    var role: LadleButtonRole = .primary
    /// Primary, secondary and destructive buttons span their container so a
    /// column of them shares one width. Tertiary buttons hug their label.
    var isFullWidth: Bool

    init(role: LadleButtonRole = .primary, isFullWidth: Bool? = nil) {
        self.role = role
        self.isFullWidth = isFullWidth ?? (role != .tertiary)
    }

    func makeBody(configuration: Configuration) -> some View {
        // The body has to be a real view rather than a modifier chain built
        // here: `@Environment` only resolves for something in the view graph,
        // and this style is also invoked by `LadlePrimaryButtonStyle`, which
        // calls `makeBody` directly. Reading `isEnabled` on the style itself
        // would silently report `true` for every delegated call site.
        Content(
            role: role,
            isFullWidth: isFullWidth,
            configuration: configuration
        )
    }

    private struct Content: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        let role: LadleButtonRole
        let isFullWidth: Bool
        let configuration: Configuration

        private var fill: Color? {
            guard isEnabled else {
                return role == .tertiary
                    ? nil
                    : LadleTheme.Intent.disabledFill
            }
            return role.fill
        }

        var body: some View {
            configuration.label
                .ladleFont(.bodyStrong)
                .foregroundStyle(
                    isEnabled ? role.label : LadleTheme.Intent.disabledLabel
                )
                .padding(
                    .horizontal,
                    role == .tertiary ? LadleTheme.Spacing.regular : 0
                )
                .frame(
                    maxWidth: isFullWidth ? .infinity : nil,
                    minHeight: LadleTheme.Control.primary
                )
                .background {
                    if let fill {
                        RoundedRectangle(
                            cornerRadius: LadleTheme.Corner.control,
                            style: .continuous
                        )
                        .fill(fill)
                    }
                }
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.86 : 1)
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
}

/// Retained so existing call sites keep working. New code states the role.
struct LadlePrimaryButtonStyle: ButtonStyle {
    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        LadleButtonStyle(role: isProminent ? .primary : .secondary)
            .makeBody(configuration: configuration)
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
