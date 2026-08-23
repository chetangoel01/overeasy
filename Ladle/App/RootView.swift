import SwiftUI

struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let accountSession: AccountSession
    let libraryViewModel: LibraryViewModel
    let importCoordinator: ImportCoordinator
    let authClient: AuthClient?
    let googleSignIn: (any GoogleSignInProviding)?
    let discoverService: any DiscoverServing
    let installationID: String
    let onAuthenticated: @MainActor () async -> Void
    let onSignOut: @MainActor () async -> Void
    let onDeleteAccount: @MainActor () async throws -> Void

    init(
        accountSession: AccountSession,
        libraryViewModel: LibraryViewModel,
        importCoordinator: ImportCoordinator,
        authClient: AuthClient? = nil,
        googleSignIn: (any GoogleSignInProviding)? = nil,
        discoverService: any DiscoverServing = DemoDiscoverService(),
        installationID: String = "preview-installation",
        onAuthenticated: @escaping @MainActor () async -> Void = {},
        onSignOut: @escaping @MainActor () async -> Void = {},
        onDeleteAccount:
            @escaping @MainActor () async throws -> Void = {}
    ) {
        self.accountSession = accountSession
        self.libraryViewModel = libraryViewModel
        self.importCoordinator = importCoordinator
        self.authClient = authClient
        self.googleSignIn = googleSignIn
        self.discoverService = discoverService
        self.installationID = installationID
        self.onAuthenticated = onAuthenticated
        self.onSignOut = onSignOut
        self.onDeleteAccount = onDeleteAccount
    }

    var body: some View {
        ZStack {
            if accountSession.shouldPresentWelcome {
                WelcomeView(
                    accountSession: accountSession,
                    authClient: authClient,
                    googleSignIn: googleSignIn,
                    installationID: installationID,
                    onAuthenticated: onAuthenticated
                )
                .transition(.opacity)
            } else if accountSession.shouldPresentWalkthrough {
                OnboardingWalkthroughView {
                    accountSession.completeWalkthrough()
                }
                .transition(.opacity)
            } else {
                LibraryView(
                    viewModel: libraryViewModel,
                    importCoordinator: importCoordinator,
                    accountSession: accountSession,
                    discoverService: discoverService,
                    installationID: installationID,
                    canImport:
                        authClient == nil
                        || accountSession.isRemoteSessionReady,
                    onSignOut: onSignOut,
                    onDeleteAccount: onDeleteAccount
                )
                .transition(.opacity)
            }
        }
        .background(LadleTheme.paper)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: accountSession.shouldPresentWelcome
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.2),
            value: accountSession.shouldPresentWalkthrough
        )
    }
}
