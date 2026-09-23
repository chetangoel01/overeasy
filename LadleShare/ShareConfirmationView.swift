import SwiftUI
import UIKit

enum ShareConfirmationState: Equatable {
    case loading
    case success(sourceName: String)
    case failure(message: String)

    /// Success feedback belongs to the save landing and nothing else: a
    /// failure, or the same confirmation rendered again, does not replay it.
    static func didSave(from old: Self, to new: Self) -> Bool {
        switch (old, new) {
        case (.loading, .success): true
        default: false
        }
    }
}

struct ShareConfirmationView: View {
    static let brandName = "Overeasy"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let state: ShareConfirmationState
    let close: () -> Void

    var body: some View {
        ZStack {
            ShareTheme.Surface.porcelain.ignoresSafeArea()

            ScrollView {
                VStack(spacing: ShareTheme.Spacing.generous) {
                    brand
                    confirmation
                    if let title = Self.dismissalTitle(for: state) {
                        Button(title, action: close)
                            .buttonStyle(SharePrimaryButtonStyle())
                            .accessibilityIdentifier("share.done")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ShareTheme.Spacing.generous)
                .padding(.vertical, ShareTheme.Spacing.generous)
            }
            .scrollIndicators(.hidden)
            // ShareViewController replaces the root view for each state, so
            // the change animates here, by value, in the view that reads
            // Reduce Motion. The copy crossfades and the source and Done fade
            // in below it; the brand and the circle hold their places.
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.2, extraBounce: 0),
                value: state
            )
        }
        .sensoryFeedback(.success, trigger: state) { old, new in
            ShareConfirmationState.didSave(from: old, to: new)
        }
        .accessibilityIdentifier("share.confirmation")
    }

    private var brand: some View {
        Label {
            Text(Self.brandName)
                .font(.headline.weight(.semibold))
        } icon: {
            Image(systemName: "frying.pan.fill")
                .foregroundStyle(ShareTheme.Label.accent)
        }
        .foregroundStyle(ShareTheme.Label.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var confirmation: some View {
        VStack(spacing: ShareTheme.Spacing.regular) {
            statusIcon

            VStack(spacing: ShareTheme.Spacing.compact) {
                Text(title)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ShareTheme.Label.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ShareTheme.Label.primary.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case let .success(sourceName) = state {
                Label(sourceName, systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ShareTheme.Label.primary.opacity(0.72))
                    .padding(.horizontal, ShareTheme.Spacing.regular)
                    .frame(minHeight: ShareTheme.Control.hitTarget)
                    .background(
                        ShareTheme.Surface.raised,
                        in: Capsule()
                    )
            }
        }
    }

    /// One circle serves every state, so a landed save fills it with accent
    /// and draws the checkmark on rather than swapping in a new view. The
    /// spinner and the failure mark keep the default fade.
    private var statusIcon: some View {
        ZStack {
            Circle().fill(
                isSaved ? ShareTheme.Intent.accent : ShareTheme.Surface.steel
            )

            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .tint(ShareTheme.Label.accent)
                    .accessibilityLabel("Saving shared recipe")
            case .success:
                Image(systemName: "checkmark")
                    .foregroundStyle(ShareTheme.Label.onAccent)
                    .transition(.symbolEffect(.drawOn))
                    .accessibilityLabel("Recipe link saved")
            case .failure:
                Image(systemName: "exclamationmark")
                    .foregroundStyle(ShareTheme.Label.accent)
                    .accessibilityLabel("Recipe link was not saved")
            }
        }
        .font(.system(size: ShareTheme.IconSize.hero, weight: .bold))
        .frame(width: 86, height: 86)
        // One 86-point element, as each of the three separate views was.
        .accessibilityElement(children: .combine)
    }

    private var isSaved: Bool {
        if case .success = state { true } else { false }
    }

    private var title: String {
        switch state {
        case .loading:
            "Saving link…"
        case .success:
            "Saved to Overeasy"
        case .failure:
            "Couldn’t save link"
        }
    }

    private var message: String {
        switch state {
        case .loading:
            "Keep this open while Overeasy saves the link."
        case .success:
            "It’ll finish importing in the app."
        case let .failure(message):
            message
        }
    }

    static func dismissalTitle(
        for state: ShareConfirmationState
    ) -> String? {
        switch state {
        case .loading:
            nil
        case .success, .failure:
            "Done"
        }
    }
}

private struct SharePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(ShareTheme.Label.onAccent)
            .frame(
                maxWidth: .infinity,
                minHeight: ShareTheme.Control.primary
            )
            .background {
                RoundedRectangle(cornerRadius: 15)
                    .fill(ShareTheme.Intent.accent)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            }
    }
}

private enum ShareTheme {
    /// Mirrors `LadleTheme.Spacing`. The extension is its own target and
    /// cannot see the app's design system, so the scale is copied here the
    /// same way the palette below already is. Two copies can drift; sharing
    /// them through LadleCore is the actual fix.
    enum Spacing {
        static let compact: CGFloat = 8
        static let regular: CGFloat = 16
        static let generous: CGFloat = 24
    }

    enum Control {
        static let hitTarget: CGFloat = 44
        static let primary: CGFloat = 52
    }

    enum IconSize {
        static let hero: CGFloat = 38
    }

    // Mirrors LadleTheme's semantic color roles. The extension is a separate
    // target, so keeping the same role names is the drift check available to
    // its call sites until the palette can move into a shared module.
    enum Surface {
        static let porcelain = adaptive(
            light: (0.969, 0.957, 0.937),
            dark: (0.063, 0.071, 0.078)
        )
        static let raised = adaptive(
            light: (0.925, 0.906, 0.882),
            dark: (0.110, 0.125, 0.141)
        )
        static let steel = adaptive(
            light: (0.890, 0.867, 0.839),
            dark: (0.145, 0.165, 0.184)
        )
    }

    enum Label {
        static let primary = adaptive(
            light: (0.078, 0.094, 0.106),
            dark: (0.949, 0.957, 0.961)
        )
        static let accent = adaptive(
            light: (0.780, 0.224, 0.141),
            dark: (1.0, 0.459, 0.384)
        )
        static let onAccent = Color(
            red: 250 / 255,
            green: 251 / 255,
            blue: 252 / 255
        )
    }

    enum Intent {
        static let accent = adaptive(
            light: (0.761, 0.231, 0.149),
            dark: (0.761, 0.231, 0.149)
        )
    }

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(
            uiColor: UIColor { traits in
                let components = traits.userInterfaceStyle == .dark
                    ? dark
                    : light
                return UIColor(
                    red: components.0,
                    green: components.1,
                    blue: components.2,
                    alpha: 1
                )
            }
        )
    }
}
