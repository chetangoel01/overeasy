import AuthenticationServices
import SwiftUI

/// The two ways into an account, as one control.
///
/// The welcome screen, the guest-limit sheet and the Settings header all
/// offer the same Apple and Google buttons. They were three copies of the
/// same twenty lines, already drifting: one clipped its Apple button and the
/// other did not, one bordered the Google control and the other did not.
struct SignInOptionsView: View {
    /// The ground the buttons sit on. It decides the two things that
    /// legitimately differ between call sites: which Apple button style
    /// reads on that ground, and whether the white Google control needs an
    /// edge to sit against.
    enum Surface {
        /// The app's paper, in either appearance.
        case porcelain
        /// The welcome screen's fixed graphite.
        case graphite
    }

    /// Google's button is supplied as a fixed-aspect image, so it cannot run
    /// full width without either stretching its wordmark or growing far
    /// taller than a control should be. Both buttons are therefore sized to
    /// that aspect at the standard control height, which is the one way the
    /// two can agree exactly — and they must, sitting one above the other.
    private static let googleAspectRatio: CGFloat = 188 / 44

    private var controlWidth: CGFloat {
        (LadleTheme.Control.primary * Self.googleAspectRatio).rounded()
    }

    @Environment(\.colorScheme) private var colorScheme

    let flow: AccountSignInFlow
    /// Prefixes the Google button's accessibility identifier, so each screen
    /// keeps the name its own tests already use.
    let identifierPrefix: String
    var surface: Surface = .porcelain

    var body: some View {
        VStack(spacing: LadleTheme.Spacing.medium) {
            SignInWithAppleButton(.continue) { request in
                flow.prepareAppleRequest(request)
            } onCompletion: { result in
                Task { await flow.handleAppleCompletion(result) }
            }
            .signInWithAppleButtonStyle(appleButtonStyle)
            .frame(width: controlWidth, height: LadleTheme.Control.primary)
            .clipShape(
                RoundedRectangle(cornerRadius: LadleTheme.Corner.control)
            )
            .disabled(flow.isAuthenticating)

            // No border here: the asset draws its own, and the porcelain
            // stroke this used to add landed on top of Google's, reading as
            // a doubled edge.
            GoogleSignInControl(
                isEnabled: !flow.isAuthenticating,
                accessibilityIdentifier: "\(identifierPrefix).google-sign-in"
            ) {
                Task { await flow.signInWithGoogle() }
            }
            .frame(width: controlWidth, height: LadleTheme.Control.primary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Graphite is fixed regardless of the device appearance, so a style
    /// chosen from `colorScheme` would be wrong half the time there — on a
    /// light-mode device it painted a black button onto #14181B.
    private var appleButtonStyle: SignInWithAppleButton.Style {
        switch surface {
        case .graphite:
            .white
        case .porcelain:
            colorScheme == .dark ? .white : .black
        }
    }
}
