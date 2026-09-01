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
            .frame(height: LadleTheme.Control.primary)
            .clipShape(
                RoundedRectangle(cornerRadius: LadleTheme.Corner.control)
            )
            .disabled(flow.isAuthenticating)

            GoogleSignInControl(
                isEnabled: !flow.isAuthenticating,
                accessibilityIdentifier: "\(identifierPrefix).google-sign-in"
            ) {
                Task { await flow.signInWithGoogle() }
            }
            .overlay {
                if surface == .porcelain {
                    RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.control,
                        style: .continuous
                    )
                    .strokeBorder(
                        LadleTheme.Label.primary.opacity(0.08),
                        lineWidth: 1
                    )
                }
            }
        }
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
