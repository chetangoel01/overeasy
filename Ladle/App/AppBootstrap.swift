import Foundation
import LadleCore
import SwiftUI

enum AppBootstrapFailureKind: Equatable {
    case localStore
    case invalidConfiguration
}

struct AppBootstrapFailure: Equatable {
    let kind: AppBootstrapFailureKind

    var diagnosticIdentifier: String {
        switch kind {
        case .localStore:
            "OE-BOOT-STORE-001"
        case .invalidConfiguration:
            "OE-BOOT-CONFIG-001"
        }
    }

    var title: String {
        switch kind {
        case .localStore:
            "Recipes couldn’t be opened"
        case .invalidConfiguration:
            "This build isn’t configured"
        }
    }

    var message: String {
        switch kind {
        case .localStore:
            "Your library was not replaced or cleared. Retry opening it before continuing."
        case .invalidConfiguration:
            "Overeasy cannot connect because this build is missing a valid service address. Install a valid build or contact support with the diagnostic below."
        }
    }

    var actionTitle: String? {
        kind == .localStore ? "Retry" : nil
    }
}

enum AppBootstrapResult {
    case preparing
    case ready(LadleRuntime)
    case failed(AppBootstrapFailure)

    var isPreparing: Bool {
        if case .preparing = self { true } else { false }
    }
}

@MainActor
struct AppBootstrap {
    typealias EnvironmentFactory = (Bool) throws -> AppEnvironment
    typealias BaseURLFactory = () throws -> URL

    private static let installationIDKey = "ladle.installation.id"

    let configuration: LadleRuntimeConfiguration
    private let makeEnvironment: EnvironmentFactory
    private let makeBaseURL: BaseURLFactory
    private let makeInstallationID: () -> String

    init(
        configuration: LadleRuntimeConfiguration,
        makeEnvironment: @escaping EnvironmentFactory = {
            try AppEnvironment(isStoredInMemoryOnly: $0)
        },
        makeBaseURL: @escaping BaseURLFactory = {
            try APIConfiguration().baseURL
        },
        makeInstallationID: (() -> String)? = nil
    ) {
        self.configuration = configuration
        self.makeEnvironment = makeEnvironment
        self.makeBaseURL = makeBaseURL
        self.makeInstallationID = makeInstallationID
            ?? Self.installationID
    }

    func run() -> AppBootstrapResult {
        let resetsBackendSession = configuration.launchArguments.contains(
            "-reset-backend-session"
        )
        if resetsBackendSession {
            Self.resetBackendSession()
        }

        let environment: AppEnvironment
        do {
            environment = try makeEnvironment(
                configuration.usesInMemoryStore
            )
            if configuration.seedsPreviewData {
                try environment.seedPreviewDataIfNeeded()
            } else if !configuration.usesInMemoryStore {
                if resetsBackendSession {
                    try environment.recipeRepository.wipeAllData()
                } else {
                    try environment.purgeDemoFixtures()
                }
            }
        } catch {
            return .failed(AppBootstrapFailure(kind: .localStore))
        }

        let services: LadleServiceConfiguration
        if configuration.usesInMemoryStore {
            services = .demo
        } else {
            do {
                services = .remote(try makeBaseURL())
            } catch {
                return .failed(
                    AppBootstrapFailure(kind: .invalidConfiguration)
                )
            }
        }

        return .ready(
            LadleRuntime(
                configuration: configuration,
                appEnvironment: environment,
                services: services,
                installationID: makeInstallationID(),
                resetsBackendSession: resetsBackendSession
            )
        )
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

enum LadleServiceConfiguration {
    case demo
    case remote(URL)
}

@MainActor
final class LadleRuntime {
    let appEnvironment: AppEnvironment
    let accountSession: AccountSession
    let syncStatus: SyncStatus
    let libraryViewModel: LibraryViewModel
    let importCoordinator: ImportCoordinator
    let authClient: AuthClient?
    let googleSignIn: GoogleSignInProvider?
    let syncService: RecipeSyncService?
    let remoteImageCache: RemoteImageCache?
    let discoverService: any DiscoverServing
    let installationID: String

    private let sharedQueueReconciler: SharedQueueReconciler?

    init(
        configuration: LadleRuntimeConfiguration,
        appEnvironment: AppEnvironment,
        services: LadleServiceConfiguration,
        installationID: String,
        resetsBackendSession: Bool
    ) {
        let launchArguments = configuration.launchArguments
        let accountSession = AccountSession(
            launchArguments: launchArguments
        )
        if launchArguments.contains("-reset-library-preferences") {
            LibraryViewModel.resetPreferences()
        }

        let sharedQueueReconciler: SharedQueueReconciler?
        if !configuration.usesInMemoryStore, !resetsBackendSession {
            let queue: (any SharedImportQueueing)?
            if let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier:
                    SharedImportQueue.appGroupIdentifier
            ) {
                queue = SharedImportQueue(
                    directoryURL: containerURL.appendingPathComponent(
                        SharedImportQueue.appGroupDirectoryName,
                        isDirectory: true
                    )
                )
            } else if let accessGroup =
                configuration.sharedKeychainAccessGroup {
                queue = SharedKeychainImportQueue(
                    accessGroup: accessGroup
                )
            } else {
                queue = nil
            }

            if let queue {
                let reconciler = SharedQueueReconciler(
                    queue: queue,
                    repository: appEnvironment.recipeRepository
                )
                _ = try? reconciler.reconcile()
                sharedQueueReconciler = reconciler
            } else {
                sharedQueueReconciler = nil
            }
        } else {
            sharedQueueReconciler = nil
        }

        let notificationService: any NotificationService
        let authClient: AuthClient?
        let googleSignIn: GoogleSignInProvider?
        let importService: any ImportService
        let syncService: RecipeSyncService?
        let remoteImageCache: RemoteImageCache?
        let discoverService: any DiscoverServing
        switch services {
        case .demo:
            notificationService = DisabledNotificationService()
            authClient = nil
            googleSignIn = nil
            importService = DemoImportService(
                slowDelay: launchArguments.contains("-ui-testing")
                    ? .seconds(30)
                    : .seconds(3)
            )
            syncService = nil
            remoteImageCache = nil
            discoverService = DemoDiscoverService()
        case let .remote(baseURL):
            notificationService = UserNotificationService()
            googleSignIn = GoogleSignInProvider()
            let tokenStore = KeychainTokenStore()
            let appAttester: AppAttestClient? = configuration.usesAppAttest
                ? AppAttestClient(
                    baseURL: baseURL,
                    installationID: installationID
                )
                : nil
            let api = APIClient(
                baseURL: baseURL,
                tokenStore: tokenStore,
                appAttester: appAttester,
                tunnelAccessKey: configuration.tunnelAccessKey,
                authenticationExpired: {
                    await MainActor.run {
                        accountSession.signOut()
                    }
                }
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
                repository: appEnvironment.recipeRepository,
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
            discoverService = RemoteDiscoverService(api: api)
        }

        let syncStatus = SyncStatus()
        let libraryViewModel = LibraryViewModel(
            repository: appEnvironment.recipeRepository,
            shuffleRecipeIDs: configuration.usesInMemoryStore
                ? { ids in
                    ids.sorted { $0.uuidString < $1.uuidString }
                }
                : { $0.shuffled() },
            didMutate: {
                await Self.performSync(
                    using: syncService,
                    status: syncStatus
                )
            }
        )
        let importCoordinator = ImportCoordinator(
            repository: appEnvironment.recipeRepository,
            service: importService,
            accountSession: accountSession,
            notificationService: notificationService,
            didCompleteRemoteImport: {
                await Self.performSync(
                    using: syncService,
                    status: syncStatus
                )
            }
        )

        self.appEnvironment = appEnvironment
        self.accountSession = accountSession
        self.syncStatus = syncStatus
        self.libraryViewModel = libraryViewModel
        self.importCoordinator = importCoordinator
        self.authClient = authClient
        self.googleSignIn = googleSignIn
        self.syncService = syncService
        self.remoteImageCache = remoteImageCache
        self.discoverService = discoverService
        self.installationID = installationID
        self.sharedQueueReconciler = sharedQueueReconciler
    }

    func restoreAndLoad() async {
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
        guard accountSession.state != .undecided else { return }
        if let syncService {
            await Self.performSync(
                using: syncService,
                status: syncStatus
            )
            await importCoordinator.resumePendingImports()
        }
        libraryViewModel.load()
    }

    func didAuthenticate() async {
        if let syncService {
            await Self.performSync(
                using: syncService,
                status: syncStatus,
                resetsCursor: true
            )
            await importCoordinator.resumePendingImports()
        }
        libraryViewModel.load()
    }

    func signOut() async {
        if let authClient {
            await authClient.signOut()
        } else {
            accountSession.signOut()
        }
        googleSignIn?.signOut()
        clearLocalSession()
    }

    func deleteAccount() async throws {
        if let authClient {
            try await authClient.deleteAccount()
        } else {
            accountSession.signOut()
        }
        await googleSignIn?.disconnect()
        clearLocalSession()
    }

    func handleOpenURL(_ url: URL) {
        _ = googleSignIn?.handle(url)
    }

    func sceneBecameActive() {
        do {
            let importedCount = try sharedQueueReconciler?.reconcile() ?? 0
            if importedCount > 0 {
                libraryViewModel.load()
                Task {
                    await importCoordinator.resumePendingImports()
                    libraryViewModel.load()
                }
            }
            Task {
                await Self.performSync(
                    using: syncService,
                    status: syncStatus
                )
                libraryViewModel.load()
            }
        } catch {
            // The durable envelope remains queued for the next activation.
            libraryViewModel.load()
        }
    }

    private func clearLocalSession() {
        libraryViewModel.clearLocalLibrary()
        try? SyncCursorStore().reset()
        syncStatus.reset()
    }

    private static func performSync(
        using service: RecipeSyncService?,
        status: SyncStatus,
        resetsCursor: Bool = false
    ) async {
        guard let service else { return }
        status.begin()
        do {
            if resetsCursor {
                try await service.resetAndSynchronize()
            } else {
                try await service.synchronize()
            }
            status.succeed()
        } catch is CancellationError {
            status.cancel()
        } catch {
            status.fail(error)
        }
    }
}

struct AppBootstrapFailureView: View {
    let failure: AppBootstrapFailure
    let retry: () -> Void

    var body: some View {
        VStack(spacing: LadleTheme.Layout.sectionGap) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: LadleTheme.IconSize.feature))
                .foregroundStyle(LadleTheme.Label.accent)
                .frame(width: 60, height: 60)
                .background(LadleTheme.Surface.steel, in: Circle())

            VStack(spacing: LadleTheme.Spacing.compact) {
                Text(failure.title)
                    .ladleFont(.title)
                    .foregroundStyle(LadleTheme.Label.primary)
                Text(failure.message)
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.Label.primary.opacity(0.64))
                    .multilineTextAlignment(.center)
            }

            Text("Diagnostic: \(failure.diagnosticIdentifier)")
                .ladleFont(.metadata)
                .foregroundStyle(LadleTheme.Label.primary.opacity(0.56))
                .textSelection(.enabled)
                .accessibilityIdentifier("bootstrap.diagnostic")

            if let actionTitle = failure.actionTitle {
                Button(actionTitle, action: retry)
                    .buttonStyle(LadleButtonStyle(role: .primary))
                    .accessibilityIdentifier("bootstrap.retry")
            }
        }
        .padding(LadleTheme.Spacing.generous)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LadleTheme.Surface.porcelain)
        .accessibilityIdentifier("bootstrap.failure")
    }
}

struct AppBootstrapPreparingView: View {
    var body: some View {
        VStack(spacing: LadleTheme.Spacing.regular) {
            ProgressView()
                .tint(LadleTheme.Label.accent)
            Text("Preparing Overeasy")
                .ladleFont(.bodyStrong)
                .foregroundStyle(LadleTheme.Label.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LadleTheme.Surface.porcelain)
        .accessibilityIdentifier("bootstrap.preparing")
    }
}
