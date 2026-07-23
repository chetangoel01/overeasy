import SwiftUI

struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let accountSession: AccountSession
    let libraryViewModel: LibraryViewModel
    let importCoordinator: ImportCoordinator

    init(
        accountSession: AccountSession,
        libraryViewModel: LibraryViewModel,
        importCoordinator: ImportCoordinator
    ) {
        self.accountSession = accountSession
        self.libraryViewModel = libraryViewModel
        self.importCoordinator = importCoordinator
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LibraryView(
                viewModel: libraryViewModel,
                importCoordinator: importCoordinator,
                accountSession: accountSession
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

                WelcomeView(accountSession: accountSession)
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
