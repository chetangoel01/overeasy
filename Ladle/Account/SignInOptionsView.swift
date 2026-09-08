import AuthenticationServices
import SwiftUI

/// Shared provider controls. Apple's unmodified artwork includes its own
/// padding; its label stays 43% of the button height, as required by HIG.
struct SignInOptionsView: View {
    @ScaledMetric(relativeTo: .body) private var preferredHeight = LadleTheme.Control.primary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var availableWidth: CGFloat = 300

    let flow: AccountSignInFlow
    let identifierPrefix: String

    private let appleTitle = String(localized: "Continue with Apple")
    private let googleTitle = String(localized: "Continue with Google")
    private let logoAspect: CGFloat = 31.0 / 44.0

    /// Grow with Dynamic Type while preserving Apple's mark/type proportions
    /// and room for the complete provider name on narrow screens.
    private var buttonHeight: CGFloat {
        let font = UIFont.systemFont(ofSize: 43, weight: .semibold)
        let labelWidth = max(
            (appleTitle as NSString).size(withAttributes: [.font: font]).width,
            (googleTitle as NSString).size(withAttributes: [.font: font]).width
        ) / 100
        let fittingHeight = availableWidth * 0.92 / (logoAspect + labelWidth)
        return max(44, min(preferredHeight, fittingHeight))
    }

    var body: some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
            GeometryReader { _ in
                providerButtons
            }
            .frame(height: buttonHeight * 2 + LadleTheme.Spacing.medium)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            failureSlot
        }
    }

    private var providerButtons: some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
            SignInWithAppleButton(.continue) { request in
                flow.prepareAppleRequest(request)
            } onCompletion: { result in
                Task { await flow.handleAppleCompletion(result) }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: buttonHeight)
            .overlay {
                authLabel(
                    mark: Image("AppleSignInLogo").resizable().scaledToFit(),
                    title: appleTitle
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: LadleTheme.Corner.control))
            .disabled(flow.isAuthenticating)
            .accessibilityIdentifier("\(identifierPrefix).apple-sign-in")

            Button {
                Task { await flow.signInWithGoogle() }
            } label: {
                authLabel(
                    mark: Image("GoogleG")
                        .resizable()
                        .scaledToFit()
                        .frame(width: buttonHeight * 19 / 44, height: buttonHeight * 19 / 44),
                    title: googleTitle
                )
            }
            .buttonStyle(.plain)
            .disabled(flow.isAuthenticating)
            .accessibilityLabel("Sign in with Google")
            .accessibilityIdentifier("\(identifierPrefix).google-sign-in")
        }
    }

    /// Reserve the usual error space, but allow longer messages to grow.
    private var failureSlot: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: LadleTheme.Spacing.compact))
            : AnyLayout(HStackLayout(spacing: LadleTheme.Spacing.compact))
        return layout {
            Text(flow.failure?.message ?? "")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(flow.failure == nil)
                .accessibilityIdentifier("\(identifierPrefix).sign-in-failure")

            if flow.canRetry {
                Button("Try Again") {
                    Task { await flow.retry() }
                }
                .buttonStyle(LadleButtonStyle(role: .tertiary))
                .disabled(flow.isAuthenticating)
                .accessibilityIdentifier("\(identifierPrefix).sign-in-retry")
            }
        }
        .frame(minHeight: LadleTheme.Control.primary)
    }

    private func authLabel(mark: some View, title: String) -> some View {
        HStack(spacing: 0) {
            mark
                .frame(width: buttonHeight * logoAspect, height: buttonHeight)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: buttonHeight * 0.43, weight: .semibold))
                .foregroundStyle(.black)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.trailing, availableWidth * 0.08)
        .frame(maxWidth: .infinity, minHeight: buttonHeight)
        .background(.white, in: RoundedRectangle(cornerRadius: LadleTheme.Corner.control))
        .overlay {
            RoundedRectangle(cornerRadius: LadleTheme.Corner.control)
                .strokeBorder(.black.opacity(0.12), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}
