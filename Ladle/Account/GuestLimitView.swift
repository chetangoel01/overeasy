import LadleCore
import SwiftUI

struct GuestLimitView: View {
    @Environment(\.ladleAccent) private var accent

    let decision: GuestSaveDecision
    var continueAction: () -> Void

    @State private var flow: AccountSignInFlow

    init(
        decision: GuestSaveDecision,
        accountSession: AccountSession,
        authClient: AuthClient?,
        googleSignIn: (any GoogleSignInProviding)?,
        onAuthenticated: @escaping @MainActor () async -> Void,
        continueAction: @escaping () -> Void
    ) {
        self.decision = decision
        self.continueAction = continueAction
        _flow = State(
            initialValue: AccountSignInFlow(
                accountSession: accountSession,
                authClient: authClient,
                googleSignIn: googleSignIn,
                onAuthenticated: onAuthenticated
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: LadleTheme.Spacing.generous) {
                LadleSheetHandle()

                Image(systemName: "books.vertical")
                    .font(.system(size: LadleTheme.IconSize.feature, weight: .semibold))
                    .foregroundStyle(accent.label)
                    .frame(width: 54, height: 54)
                    .background(LadleTheme.Surface.badge, in: Circle())

                VStack(spacing: LadleTheme.Spacing.compact) {
                    Text(title)
                        .ladleFont(.title)
                        .foregroundStyle(LadleTheme.Label.primary)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .ladleFont(.body)
                        .foregroundStyle(LadleTheme.Label.primary.opacity(0.65))
                        .multilineTextAlignment(.center)
                }

                SignInOptionsView(
                    flow: flow,
                    identifierPrefix: "guest-limit"
                )

                if decision == .allowWithAccountPrompt {
                    Button("Save recipe and continue", action: continueAction)
                        .buttonStyle(LadleButtonStyle(role: .secondary))
                        .disabled(flow.isAuthenticating)
                }

                if flow.isAuthenticating {
                    ProgressView("Creating your free account")
                        .ladleFont(.metadata)
                        .tint(accent.intent)
                        .foregroundStyle(LadleTheme.Label.secondary)
                }

            }
            .padding(LadleTheme.Spacing.generous)
        }
        .scrollIndicators(.hidden)
        .background(LadleTheme.Surface.porcelain)
    }

    private var title: String {
        switch decision {
        case .allow, .allowWithAccountPrompt:
            "One spot left"
        case .limitReached:
            "Your recipes are safe"
        }
    }

    private var message: String {
        switch decision {
        case .allow:
            "You can keep saving recipes as a guest."
        case .allowWithAccountPrompt:
            "This will be your tenth guest recipe. A free account keeps future saves unlimited."
        case .limitReached:
            "Your 10 guest recipes stay available. Create a free account to save another one."
        }
    }
}
