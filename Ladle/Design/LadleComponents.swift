import SwiftUI

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
            .overlay {
                if !isProminent {
                    RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.control,
                        style: .continuous
                    )
                    .stroke(LadleTheme.ink.opacity(0.12), lineWidth: 1)
                }
            }
            .opacity(
                !isEnabled
                    ? 0.48
                    : (configuration.isPressed ? 0.72 : 1)
            )
            .scaleEffect(
                reduceMotion || !isEnabled
                    ? 1
                    : (configuration.isPressed ? 0.985 : 1)
            )
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
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
        case .primary, .onDark:
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
        .buttonStyle(.plain)
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
                LadleTheme.paper,
                in: RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.card,
                    style: .continuous
                )
                .stroke(LadleTheme.ink.opacity(0.09), lineWidth: 1)
            }
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
