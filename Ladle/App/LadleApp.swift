import LadleCore
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
    @Environment(\.scenePhase) private var scenePhase

    private let appEnvironment: AppEnvironment
    private let sharedQueueReconciler: SharedQueueReconciler?
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

        let sharedQueueReconciler: SharedQueueReconciler?
        if !runtimeConfiguration.usesInMemoryStore,
           let containerURL = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier:
                   SharedImportQueue.appGroupIdentifier
           ) {
            let queue = SharedImportQueue(
                directoryURL: containerURL.appendingPathComponent(
                    SharedImportQueue.appGroupDirectoryName,
                    isDirectory: true
                )
            )
            let reconciler = SharedQueueReconciler(
                queue: queue,
                repository: environment.recipeRepository
            )
            _ = try? reconciler.reconcile()
            sharedQueueReconciler = reconciler
        } else {
            sharedQueueReconciler = nil
        }

        let accountSession = AccountSession(
            launchArguments: launchArguments
        )
        let notificationService: any NotificationService =
            runtimeConfiguration.usesInMemoryStore
                ? DisabledNotificationService()
                : UserNotificationService()

        appEnvironment = environment
        self.sharedQueueReconciler = sharedQueueReconciler
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
                accountSession: accountSession,
                notificationService: notificationService
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
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active,
                          let sharedQueueReconciler else {
                        return
                    }
                    do {
                        let importedCount =
                            try sharedQueueReconciler.reconcile()
                        if importedCount > 0 {
                            libraryViewModel.load()
                        }
                    } catch {
                        // The durable envelope remains queued for the next activation.
                        libraryViewModel.load()
                    }
                }
        }
    }
}
