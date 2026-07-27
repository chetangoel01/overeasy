import SwiftUI
import UIKit

enum ShareConfirmationState: Equatable {
    case loading
    case success(sourceName: String)
    case failure(message: String)
}

struct ShareConfirmationView: View {
    static let brandName = "Overeasy"

    let state: ShareConfirmationState
    let close: () -> Void

    var body: some View {
        ZStack {
            ShareTheme.paper.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {
                    brand
                    confirmation
                    footer
                    if let title = Self.dismissalTitle(for: state) {
                        Button(title, action: close)
                            .buttonStyle(SharePrimaryButtonStyle())
                            .accessibilityIdentifier("share.done")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("share.confirmation")
    }

    private var brand: some View {
        Label {
            Text(Self.brandName)
                .font(
                    .system(
                        .headline,
                        design: .rounded,
                        weight: .bold
                    )
                )
        } icon: {
            Image(systemName: "frying.pan.fill")
                .foregroundStyle(ShareTheme.brick)
        }
        .foregroundStyle(ShareTheme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var confirmation: some View {
        VStack(spacing: 20) {
            statusIcon

            VStack(spacing: 10) {
                Text(title)
                    .font(
                        .system(
                            .title,
                            design: .rounded,
                            weight: .bold
                        )
                    )
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ShareTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ShareTheme.ink.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case let .success(sourceName) = state {
                Label(sourceName, systemImage: "link")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ShareTheme.ink.opacity(0.72))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(
                        ShareTheme.field,
                        in: Capsule()
                    )
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(ShareTheme.brick)
                .frame(width: 86, height: 86)
                .background(ShareTheme.review, in: Circle())
                .accessibilityLabel("Saving shared recipe")
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(ShareTheme.onAccent)
                .frame(width: 86, height: 86)
                .background(ShareTheme.brick, in: Circle())
                .accessibilityLabel("Recipe link saved")
        case .failure:
            Image(systemName: "exclamationmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(ShareTheme.brick)
                .frame(width: 86, height: 86)
                .background(ShareTheme.review, in: Circle())
                .accessibilityLabel("Recipe link was not saved")
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if case .success = state {
                Text("Safe to close")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ShareTheme.ink.opacity(0.58))
            }

            Text(footerMessage)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(ShareTheme.ink.opacity(0.48))
        }
    }

    private var title: String {
        switch state {
        case .loading:
            "Catching that recipe…"
        case .success:
            "Recipe link saved"
        case .failure:
            "One more try?"
        }
    }

    private var message: String {
        switch state {
        case .loading:
            "Hold on for just a moment while the link is secured."
        case .success:
            "Head back to what you were watching. Overeasy will finish the import in the app."
        case let .failure(message):
            message
        }
    }

    private var footerMessage: String {
        switch state {
        case .loading:
            "This should only take a moment."
        case .success:
            "No need to wait for the recipe to be parsed."
        case .failure:
            "Close this sheet and share the link again."
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
            .foregroundStyle(ShareTheme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                ShareTheme.brick.opacity(
                    configuration.isPressed ? 0.78 : 1
                ),
                in: RoundedRectangle(cornerRadius: 15)
            )
    }
}

private enum ShareTheme {
    static let paper = adaptive(
        light: (0.980, 0.965, 0.937),
        dark: (0.114, 0.098, 0.110)
    )
    static let field = adaptive(
        light: (0.949, 0.925, 0.894),
        dark: (0.157, 0.133, 0.149)
    )
    static let review = adaptive(
        light: (0.867, 0.835, 0.875),
        dark: (0.200, 0.169, 0.192)
    )
    static let brick = Color(
        red: 0.678,
        green: 0.314,
        blue: 0.239
    )
    static let ink = adaptive(
        light: (0.188, 0.153, 0.176),
        dark: (0.969, 0.941, 0.910)
    )
    static let onAccent = Color(
        red: 1,
        green: 249 / 255,
        blue: 240 / 255
    )

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
