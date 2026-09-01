import AuthenticationServices
import LadleCore
import SwiftUI

struct GuestLimitView: View {
    @Environment(\.ladleAccent) private var accent

    let decision: GuestSaveDecision
    var continueAction: () -> Void

    @Environment(\.colorScheme) private var colorScheme

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

                VStack(spacing: LadleTheme.Spacing.medium) {
                    SignInWithAppleButton(.continue) { request in
                        flow.prepareAppleRequest(request)
                    } onCompletion: { result in
                        Task { await flow.handleAppleCompletion(result) }
                    }
                    // Unlike the welcome screen's fixed graphite, porcelain
                    // adapts to the appearance, so the button must too.
                    .signInWithAppleButtonStyle(
                        colorScheme == .dark ? .white : .black
                    )
                    .frame(height: LadleTheme.Control.primary)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: LadleTheme.Corner.control
                        )
                    )
                    .disabled(flow.isAuthenticating)

                    GoogleSignInControl(
                        isEnabled: !flow.isAuthenticating,
                        accessibilityIdentifier: "guest-limit.google-sign-in"
                    ) {
                        Task { await flow.signInWithGoogle() }
                    }
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: LadleTheme.Corner.control,
                            style: .continuous
                        )
                        .strokeBorder(
                            LadleTheme.Label.primary.opacity(0.08),
                            lineWidth: 1
                        )
                    )
                }

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

                if let failure = flow.failure {
                    Text(failure.message)
                        .ladleFont(.metadata)
                        .foregroundStyle(accent.label)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("guest-limit.sign-in-failure")
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
