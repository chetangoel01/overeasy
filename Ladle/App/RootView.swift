import SwiftUI

struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let accountSession: AccountSession
    let libraryViewModel: LibraryViewModel
    let importCoordinator: ImportCoordinator
    let authClient: AuthClient?
    let installationID: String
    let onAuthenticated: @MainActor () async -> Void
    let onSignOut: @MainActor () async -> Void

    init(
        accountSession: AccountSession,
        libraryViewModel: LibraryViewModel,
        importCoordinator: ImportCoordinator,
        authClient: AuthClient? = nil,
        installationID: String = "preview-installation",
        onAuthenticated: @escaping @MainActor () async -> Void = {},
        onSignOut: @escaping @MainActor () async -> Void = {}
    ) {
        self.accountSession = accountSession
        self.libraryViewModel = libraryViewModel
        self.importCoordinator = importCoordinator
        self.authClient = authClient
        self.installationID = installationID
        self.onAuthenticated = onAuthenticated
        self.onSignOut = onSignOut
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LibraryView(
                viewModel: libraryViewModel,
                importCoordinator: importCoordinator,
                accountSession: accountSession,
                installationID: installationID,
                canImport:
                    authClient == nil
                    || accountSession.isRemoteSessionReady,
                onSignOut: onSignOut
            )
                .blur(
                    radius: accountSession.shouldPresentWelcome ? 2.5 : 0
                )
                .allowsHitTesting(!accountSession.shouldPresentWelcome)

            if accountSession.shouldPresentWelcome {
                LadleTheme.ink
                    .opacity(0.28)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                WelcomeView(
                    accountSession: accountSession,
                    authClient: authClient,
                    installationID: installationID,
                    onAuthenticated: onAuthenticated
                )
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .bottom)
                                .combined(with: .opacity)
                    )
            }
        }
        .background(LadleTheme.paper)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.34),
            value: accountSession.shouldPresentWelcome
        )
    }
}
