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
    @State private var importCoordinator: ImportCoordinator

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

        let accountSession = AccountSession(
            launchArguments: launchArguments
        )

        appEnvironment = environment
        _accountSession = State(
            initialValue: accountSession
        )
        _libraryViewModel = State(
            initialValue: LibraryViewModel(
                repository: environment.recipeRepository
            )
        )
        _importCoordinator = State(
            initialValue: ImportCoordinator(
                repository: environment.recipeRepository,
                service: DemoImportService(),
                accountSession: accountSession
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                accountSession: accountSession,
                libraryViewModel: libraryViewModel,
                importCoordinator: importCoordinator
            )
                .tint(LadleTheme.paprika)
                .modelContainer(appEnvironment.modelContainer)
        }
    }
}
