import SwiftUI

struct RootView: View {
    let accountSession: AccountSession
    let libraryViewModel: LibraryViewModel

    init(
        accountSession: AccountSession,
        libraryViewModel: LibraryViewModel
    ) {
        self.accountSession = accountSession
        self.libraryViewModel = libraryViewModel
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LibraryView(viewModel: libraryViewModel)
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
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                    )
            }
        }
        .background(LadleTheme.paper)
        .animation(
            .snappy(duration: 0.34),
            value: accountSession.shouldPresentWelcome
        )
    }
}
