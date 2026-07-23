import SwiftData
import SwiftUI

struct LadleRuntimeConfiguration {
    let launchArguments: [String]
    let environment: [String: String]

    var usesInMemoryStore: Bool {
        launchArguments.contains("-ui-testing")
            || environment["XCTestConfigurationFilePath"] != nil
    }
}

@main
struct LadleApp: App {
    private let appEnvironment: AppEnvironment
    @State private var accountSession: AccountSession
    @State private var libraryViewModel: LibraryViewModel

    init() {
        let processInfo = ProcessInfo.processInfo
        let launchArguments = processInfo.arguments
        let runtimeConfiguration = LadleRuntimeConfiguration(
            launchArguments: launchArguments,
            environment: processInfo.environment
        )
        let environment: AppEnvironment

        do {
            environment = try AppEnvironment(
                isStoredInMemoryOnly: runtimeConfiguration.usesInMemoryStore
            )
            try environment.seedPreviewDataIfNeeded()
        } catch {
            fatalError("Ladle could not initialize its recipe store: \(error)")
        }

        if launchArguments.contains("-reset-library-preferences") {
            LibraryViewModel.resetDisplayPreference()
        }

        appEnvironment = environment
        _accountSession = State(
            initialValue: AccountSession(launchArguments: launchArguments)
        )
        _libraryViewModel = State(
            initialValue: LibraryViewModel(
                repository: environment.recipeRepository
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                accountSession: accountSession,
                libraryViewModel: libraryViewModel
            )
                .tint(LadleTheme.paprika)
                .modelContainer(appEnvironment.modelContainer)
        }
    }
}
