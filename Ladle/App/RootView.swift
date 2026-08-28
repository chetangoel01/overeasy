import SwiftUI

struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let accountSession: AccountSession
    let libraryViewModel: LibraryViewModel
    let importCoordinator: ImportCoordinator
    let authClient: AuthClient?
    let googleSignIn: (any GoogleSignInProviding)?
    let discoverService: any DiscoverServing
    let syncStatus: SyncStatus
    let notificationNavigation: NotificationNavigation
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
        syncStatus: SyncStatus = SyncStatus(),
        notificationNavigation: NotificationNavigation = .shared,
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
        self.syncStatus = syncStatus
        self.notificationNavigation = notificationNavigation
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
                    authClient: authClient,
                    googleSignIn: googleSignIn,
                    discoverService: discoverService,
                    syncStatus: syncStatus,
                    notificationNavigation: notificationNavigation,
                    canImport:
                        authClient == nil
                        || accountSession.isRemoteSessionReady,
                    onAuthenticated: onAuthenticated,
                    onSignOut: onSignOut,
                    onDeleteAccount: onDeleteAccount
                )
                .transition(.opacity)
            }
        }
        .background(LadleTheme.Surface.porcelain)
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
