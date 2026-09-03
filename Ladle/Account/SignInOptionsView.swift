import AuthenticationServices
import SwiftUI

/// The two ways into an account, as one control.
///
/// The welcome screen, the guest-limit sheet and the Settings header all
/// offer the same Apple and Google buttons. They were three copies of the
/// same twenty lines, already drifting: one clipped its Apple button and the
/// other did not, one bordered the Google control and the other did not.
struct SignInOptionsView: View {
    /// The ground the buttons sit on.
    ///
    /// Kept because call sites pass it, but it no longer changes how the
    /// buttons look. Both are now the same white pill in every context —
    /// see `authLabel`.
    enum Surface {
        /// The app's paper, in either appearance.
        case porcelain
        /// The welcome screen's fixed graphite.
        case graphite
    }

    /// Both buttons are drawn by us, in fixed colours, so that they are
    /// identical on every surface and in both appearances.
    ///
    /// They used to be Apple's stock control stacked on Google's supplied
    /// image: a black-or-white system pill above a grey one with different
    /// metrics and a different wordmark treatment. Two buttons doing the same
    /// job should not look like they came from different apps, and the pair
    /// read worse than either did alone. Apple and Google both permit a
    /// custom button built from their mark and approved wording, which is
    /// the only way the two can actually match.
    private enum Chrome {
        static let background = Color.white
        static let label = Color(red: 0.12, green: 0.12, blue: 0.13)
        static let border = Color.black.opacity(0.12)
        static let markSide: CGFloat = 20
        static let gap: CGFloat = 10
    }

    let flow: AccountSignInFlow
    /// Prefixes the Google button's accessibility identifier, so each screen
    /// keeps the name its own tests already use.
    let identifierPrefix: String
    var surface: Surface = .porcelain

    var body: some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
            // Apple's control still performs the authorization — the request
            // and completion callbacks are its own — but our label is laid
            // over it so the two buttons match. The overlay does not hit
            // test, so every tap still reaches Apple's button underneath.
            SignInWithAppleButton(.continue) { request in
                flow.prepareAppleRequest(request)
            } onCompletion: { result in
                Task { await flow.handleAppleCompletion(result) }
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: LadleTheme.Control.primary)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.control,
                    style: .continuous
                )
            )
            .overlay {
                authLabel(
                    mark: Image(systemName: "apple.logo")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Chrome.label),
                    title: "Continue with Apple"
                )
                .allowsHitTesting(false)
            }
            .disabled(flow.isAuthenticating)

            Button {
                Task { await flow.signInWithGoogle() }
            } label: {
                authLabel(
                    mark: Image("GoogleG")
                        .resizable()
                        .scaledToFit(),
                    title: "Continue with Google"
                )
            }
            .buttonStyle(.plain)
            .disabled(flow.isAuthenticating)
            .accessibilityLabel("Sign in with Google")
            .accessibilityIdentifier("\(identifierPrefix).google-sign-in")
        }
    }

    private func authLabel(
        mark: some View,
        title: String
    ) -> some View {
        HStack(spacing: Chrome.gap) {
            mark
                .frame(width: Chrome.markSide, height: Chrome.markSide)
                .accessibilityHidden(true)
            Text(title)
                .ladleFont(.bodyStrong)
                .foregroundStyle(Chrome.label)
        }
        .frame(
            maxWidth: .infinity,
            minHeight: LadleTheme.Control.primary
        )
        .background(
            Chrome.background,
            in: RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: LadleTheme.Corner.control,
                style: .continuous
            )
            .strokeBorder(Chrome.border, lineWidth: 1)
        }
        .contentShape(Rectangle())
    }
}
