import Foundation
import SwiftData
import SwiftUI
import UIKit

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

    var demoScenario: DemoLaunchScenario {
        guard launchArguments.contains("-ui-testing")
                || launchArguments.contains("-empty-library")
        else { return .standard }
        return DemoLaunchScenario(launchArguments: launchArguments)
    }

    var seedsPreviewData: Bool {
        usesInMemoryStore && demoScenario.seedsRecipes
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

    var sharedKeychainAccessGroup: String? {
        guard
            let value = infoDictionary[
                "LadleSharedKeychainAccessGroup"
            ] as? String,
            !value.isEmpty
        else {
            return nil
        }
        return value
    }
}

@main
struct LadleApp: App {
    @AppStorage(LadleAccentColor.preferenceKey)
    private var accentColor = LadleAccentColor.tomato.rawValue
    @State private var bootstrapResult = AppBootstrapResult.preparing

    @UIApplicationDelegateAdaptor(LadleAppDelegate.self)
    private var appDelegate

    private let bootstrap: AppBootstrap

    init() {
        Self.configureSegmentedControlAppearance()
        let processInfo = ProcessInfo.processInfo
        bootstrap = AppBootstrap(
            configuration: LadleRuntimeConfiguration(
                launchArguments: processInfo.arguments,
                environment: processInfo.environment
            )
        )
    }

    /// The system's selected-segment thumb is a grey that vanishes against
    /// the dark chrome over Watch video. A white pill with ink text reads on
    /// both that chrome and the light in-app tracks, which already looked
    /// this way. Unselected titles are left to the system so they keep
    /// adapting to the surrounding colour scheme.
    private static func configureSegmentedControlAppearance() {
        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = .white
        segmented.setTitleTextAttributes(
            [.foregroundColor: UIColor(LadleTheme.Label.onFixedPale)],
            for: .selected
        )
    }

    var body: some Scene {
        WindowGroup {
            content
                .tint(
                    LadleAccentColor.resolve(
                        storedValue: accentColor
                    ).textColor
                )
                .task {
                    guard bootstrapResult.isPreparing else { return }
                    bootstrapResult = bootstrap.run()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch bootstrapResult {
        case .preparing:
            AppBootstrapPreparingView()
        case let .failed(failure):
            AppBootstrapFailureView(
                failure: failure,
                retry: retryBootstrap
            )
        case let .ready(runtime):
            LadleRuntimeView(runtime: runtime)
        }
    }

    private func retryBootstrap() {
        bootstrapResult = .preparing
        Task { @MainActor in
            await Task.yield()
            bootstrapResult = bootstrap.run()
        }
    }
}

private struct LadleRuntimeView: View {
    @Environment(\.scenePhase) private var scenePhase

    let runtime: LadleRuntime

    var body: some View {
        RootView(
            accountSession: runtime.accountSession,
            libraryViewModel: runtime.libraryViewModel,
            importCoordinator: runtime.importCoordinator,
            authClient: runtime.authClient,
            googleSignIn: runtime.googleSignIn,
            discoverService: runtime.discoverService,
            syncStatus: runtime.syncStatus,
            notificationNavigation: .shared,
            onAuthenticated: runtime.didAuthenticate,
            onSignOut: runtime.signOut,
            onDeleteAccount: runtime.deleteAccount
        )
        .modelContainer(runtime.appEnvironment.modelContainer)
        .environment(\.remoteImageCache, runtime.remoteImageCache)
        .onOpenURL(perform: runtime.handleOpenURL)
        .task {
            await runtime.restoreAndLoad()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            runtime.sceneBecameActive()
        }
    }
}
