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
    private let authClient: AuthClient?
    private let syncService: RecipeSyncService?
    private let remoteImageCache: RemoteImageCache?
    private let installationID: String
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
        let accountSession = AccountSession(
            launchArguments: launchArguments
        )
        let environment: AppEnvironment

        do {
            environment = try AppEnvironment(
                isStoredInMemoryOnly: runtimeConfiguration.usesInMemoryStore
            )
            if runtimeConfiguration.usesInMemoryStore {
                try environment.seedPreviewDataIfNeeded()
            }
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

        let notificationService: any NotificationService =
            runtimeConfiguration.usesInMemoryStore
                ? DisabledNotificationService()
                : UserNotificationService()

        let authClient: AuthClient?
        let importService: any ImportService
        let syncService: RecipeSyncService?
        let remoteImageCache: RemoteImageCache?
        if runtimeConfiguration.usesInMemoryStore {
            authClient = nil
            importService = DemoImportService(
                slowDelay: launchArguments.contains("-ui-testing")
                    ? .seconds(30)
                    : .seconds(3)
            )
            syncService = nil
            remoteImageCache = nil
        } else {
            do {
                let tokenStore = KeychainTokenStore()
                let api = APIClient(
                    baseURL: try APIConfiguration().baseURL,
                    tokenStore: tokenStore
                )
                authClient = AuthClient(
                    api: api,
                    tokenStore: tokenStore,
                    accountSession: accountSession
                )
                importService = RemoteImportService(api: api)
                syncService = RecipeSyncService(
                    api: api,
                    repository: environment.recipeRepository,
                    cursorStore: SyncCursorStore()
                )
                let cacheRoot = FileManager.default.urls(
                    for: .cachesDirectory,
                    in: .userDomainMask
                )[0]
                remoteImageCache = RemoteImageCache(
                    directoryURL: cacheRoot.appendingPathComponent(
                        "recipe-artwork",
                        isDirectory: true
                    ),
                    api: api
                )
            } catch {
                fatalError(
                    "Ladle could not initialize its API configuration: \(error)"
                )
            }
        }
        let installationID = Self.installationID()

        appEnvironment = environment
        self.sharedQueueReconciler = sharedQueueReconciler
        self.authClient = authClient
        self.syncService = syncService
        self.remoteImageCache = remoteImageCache
        self.installationID = installationID
        _accountSession = State(
            initialValue: accountSession
        )
        _libraryViewModel = State(
            initialValue: LibraryViewModel(
                repository: environment.recipeRepository,
                didMutate: {
                    try? await syncService?.synchronize()
                }
            )
        )
        _importCoordinator = State(
            initialValue: ImportCoordinator(
                repository: environment.recipeRepository,
                service: importService,
                accountSession: accountSession,
                notificationService: notificationService,
                didCompleteRemoteImport: {
                    try? await syncService?.synchronize()
                }
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                accountSession: accountSession,
                libraryViewModel: libraryViewModel,
                importCoordinator: importCoordinator,
                authClient: authClient,
                installationID: installationID,
                onAuthenticated: {
                    if let syncService {
                        try? await syncService.resetAndSynchronize()
                        await importCoordinator.resumePendingImports()
                    }
                    libraryViewModel.load()
                }
            )
                .tint(LadleTheme.paprika)
                .modelContainer(appEnvironment.modelContainer)
                .environment(\.remoteImageCache, remoteImageCache)
                .task {
                    if let authClient {
                        do {
                            let restored = try authClient.restoreSession()
                            if restored == nil,
                               accountSession.state != .undecided {
                                _ = try await authClient.bootstrapGuest(
                                    installationID: installationID,
                                    attestation: nil
                                )
                            }
                        } catch {
                            return
                        }
                    }
                    guard accountSession.state != .undecided else {
                        return
                    }
                    if let syncService {
                        try? await syncService.synchronize()
                        await importCoordinator.resumePendingImports()
                    }
                    libraryViewModel.load()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else {
                        return
                    }
                    do {
                        let importedCount = try sharedQueueReconciler?
                            .reconcile() ?? 0
                        if importedCount > 0 {
                            libraryViewModel.load()
                            Task {
                                await importCoordinator
                                    .resumePendingImports()
                                libraryViewModel.load()
                            }
                        }
                        Task {
                            try? await syncService?.synchronize()
                            libraryViewModel.load()
                        }
                    } catch {
                        // The durable envelope remains queued for the next activation.
                        libraryViewModel.load()
                    }
                }
        }
    }

    private static func installationID() -> String {
        let key = "ladle.installation.id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}
