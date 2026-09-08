import SwiftUI

struct AccountSignInView: View {
    @Environment(\.dismiss) private var dismiss
    let accountSession: AccountSession
    @State private var flow: AccountSignInFlow

    init(
        accountSession: AccountSession,
        authClient: AuthClient?,
        googleSignIn: (any GoogleSignInProviding)?,
        onAuthenticated: @escaping @MainActor () async -> Void
    ) {
        self.accountSession = accountSession
        _flow = State(initialValue: AccountSignInFlow(
            accountSession: accountSession, authClient: authClient,
            googleSignIn: googleSignIn, onAuthenticated: onAuthenticated
        ))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: LadleTheme.Spacing.generous) {
                Text("Keep your recipes in sync")
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.Label.primary)
                Text("Signing in keeps everything you have saved and lifts the 10-recipe guest limit.")
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.Label.secondary)
                SignInOptionsView(flow: flow, identifierPrefix: "account")
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(LadleTheme.Layout.sheetMargin)
        }
        .background(LadleTheme.Surface.porcelain)
        .navigationTitle("Sign in")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: accountSession.state) { _, state in
            if state != .guest, state != .undecided { dismiss() }
        }
    }
}
