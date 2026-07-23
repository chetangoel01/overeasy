import SwiftUI

@main
struct LadleApp: App {
    @State private var accountSession = AccountSession()

    var body: some Scene {
        WindowGroup {
            RootView(accountSession: accountSession)
                .tint(LadleTheme.paprika)
        }
    }
}
