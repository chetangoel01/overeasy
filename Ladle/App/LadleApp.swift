import Foundation
import LadleCore
import SwiftData
import SwiftUI

struct LadleRuntimeConfiguration {
    let launchArguments: [String]
    let environment: [String: String]
    private let infoDictionary: [String: Any]

    init(
        launchArguments: [String],
        environment: [String: String],
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        self.launchArguments = launchArguments
        self.environment = environment
        self.infoDictionary = infoDictionary
    }

    var usesInMemoryStore: Bool {
        launchArguments.contains("-ui-testing")
            || environment["XCTestConfigurationFilePath"] != nil
    }

    var seedsPreviewData: Bool {
        usesInMemoryStore && !launchArguments.contains("-empty-library")
    }

    var usesAppAttest: Bool {
        guard
            let value = infoDictionary["LadleAppAttestEnabled"] as? String
        else {
            return true
        }
        return !["0", "false", "no"].contains(value.lowercased())
    }

    var tunnelAccessKey: String? {
        guard
            let value = infoDictionary["LadleTunnelAccessKey"] as? String,
            !value.isEmpty
        else {
            return nil
        }
        return value
    }
}

@main
struct LadleApp: App {
    private static let installationIDKey = "ladle.installation.id"

    @Environment(\.scenePhase) private var scenePhase

    private let appEnvironment: AppEnvironment
    private let sharedQueueReconciler: SharedQueueReconciler?
    private let authClient: AuthClient?
    private let googleSignIn: GoogleSignInProvider?
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
        let resetsBackendSession = launchArguments.contains(
            "-reset-backend-session"
        )
        if resetsBackendSession {
            Self.resetBackendSession()
        }
        let installationID = Self.installationID()
        let accountSession = AccountSession(
            launchArguments: launchArguments
        )
        let environment: AppEnvironment

        do {
            environment = try AppEnvironment(
                isStoredInMemoryOnly: runtimeConfiguration.usesInMemoryStore
            )
            if runtimeConfiguration.seedsPreviewData {
                try environment.seedPreviewDataIfNeeded()
            } else if !runtimeConfiguration.usesInMemoryStore {
                if resetsBackendSession {
                    try environment.recipeRepository.wipeAllData()
                } else {
                    try environment.purgeDemoFixtures()
                }
            }
        } catch {
            fatalError("Overeasy could not initialize its recipe store: \(error)")
        }

        if launchArguments.contains("-reset-library-preferences") {
            LibraryViewModel.resetPreferences()
        }

        let sharedQueueReconciler: SharedQueueReconciler?
        if !runtimeConfiguration.usesInMemoryStore,
           !resetsBackendSession,
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
        let googleSignIn = runtimeConfiguration.usesInMemoryStore
            ? nil
            : GoogleSignInProvider()

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
                let baseURL = try APIConfiguration().baseURL
                let appAttester: AppAttestClient? =
                    runtimeConfiguration.usesAppAttest
                    ? AppAttestClient(
                        baseURL: baseURL,
                        installationID: installationID
                    )
                    : nil
                let api = APIClient(
                    baseURL: baseURL,
                    tokenStore: tokenStore,
                    appAttester: appAttester,
                    tunnelAccessKey: runtimeConfiguration.tunnelAccessKey
                )
                authClient = AuthClient(
                    api: api,
                    tokenStore: tokenStore,
                    accountSession: accountSession,
                    appAttester: appAttester
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
                    "Overeasy could not initialize its API configuration: \(error)"
                )
            }
        }
        appEnvironment = environment
        self.sharedQueueReconciler = sharedQueueReconciler
        self.authClient = authClient
        self.googleSignIn = googleSignIn
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
                googleSignIn: googleSignIn,
                installationID: installationID,
                onAuthenticated: {
                    if let syncService {
                        try? await syncService.resetAndSynchronize()
                        await importCoordinator.resumePendingImports()
                    }
                    libraryViewModel.load()
                },
                onSignOut: { [authClient, accountSession, libraryViewModel] in
                    if let authClient {
                        await authClient.signOut()
                    } else {
                        accountSession.signOut()
                    }
                    googleSignIn?.signOut()
                    libraryViewModel.clearLocalLibrary()
                    try? SyncCursorStore().reset()
                },
                onDeleteAccount: {
                    [authClient, accountSession, libraryViewModel] in
                    if let authClient {
                        try await authClient.deleteAccount()
                    } else {
                        accountSession.signOut()
                    }
                    await googleSignIn?.disconnect()
                    libraryViewModel.clearLocalLibrary()
                    try? SyncCursorStore().reset()
                }
            )
                .tint(LadleTheme.paprika)
                .modelContainer(appEnvironment.modelContainer)
                .environment(\.remoteImageCache, remoteImageCache)
                .onOpenURL { url in
                    _ = googleSignIn?.handle(url)
                }
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
        if let existing = UserDefaults.standard.string(
            forKey: installationIDKey
        ) {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: installationIDKey)
        return created
    }

    private static func resetBackendSession() {
        try? KeychainTokenStore().clear()
        try? SyncCursorStore().reset()
        UserDefaults.standard.removeObject(forKey: installationIDKey)
    }
}
