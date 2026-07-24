import SwiftUI

struct LadlePrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isProminent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .ladleFont(.bodyStrong)
            .foregroundStyle(isProminent ? Color.white : LadleTheme.ink)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                isProminent ? LadleTheme.paprika : LadleTheme.field,
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
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(
                reduceMotion
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
                .foregroundStyle(LadleTheme.ink.opacity(0.58))
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
