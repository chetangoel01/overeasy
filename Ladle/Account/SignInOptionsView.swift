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
        /// Three lines of metadata text beside a Try Again button, reserved
        /// whether or not a failure is showing, so appearing never moves the
        /// screen. A tertiary control's own height, because that is what the
        /// button is; the message is shorter than that and centres in it.
        static let failureSlotHeight = LadleTheme.Control.primary
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

            failureSlot
        }
    }

    /// Always laid out, whether or not there is anything to say.
    ///
    /// The failure used to be an `if let` appended by each call site. Both
    /// place these buttons inside a vertically centred stack, so the moment
    /// a sign-in failed the message appeared, the stack grew, and everything
    /// above it — logo, headline, both buttons — jumped upward, at the exact
    /// moment the reader was trying to find out what went wrong.
    ///
    /// The slot keeps a constant height instead. Messages vary in length, so
    /// the text is bounded rather than the box: three lines, scaling down
    /// before it would grow. Nothing on the screen moves.
    ///
    /// Try Again sits inside that same slot, beside the message rather than
    /// under it, for the same reason: a button appearing on its own row
    /// would move the screen exactly as the message used to. It is offered
    /// only where re-sending would help — a 5xx from our own backend — and
    /// it re-issues that request without re-presenting the provider sheet
    /// the cook has already answered.
    private var failureSlot: some View {
        HStack(spacing: LadleTheme.Spacing.compact) {
            Text(flow.failure?.message ?? "")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
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
        .frame(height: Chrome.failureSlotHeight)
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
