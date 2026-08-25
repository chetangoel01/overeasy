import XCTest
import LadleCore
import SwiftUI
@testable import Ladle

@MainActor
final class ProjectSmokeTests: XCTestCase {
    func testPrimaryScreensAvoidRedundantExplanatoryHeadings() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let library = try String(
            contentsOf: project.appendingPathComponent(
                "Ladle/Library/AllRecipesView.swift"
            ),
            encoding: .utf8
        )
        let detail = try String(
            contentsOf: project.appendingPathComponent(
                "Ladle/RecipeDetail/RecipeDetailView.swift"
            ),
            encoding: .utf8
        )
        let cooking = try String(
            contentsOf: project.appendingPathComponent(
                "Ladle/Cooking/FullRecipeView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(library.contains("Return to saved recipe videos"))
        XCTAssertFalse(library.contains("Useful groups"))
        XCTAssertFalse(detail.contains("Text(kicker)"))
        XCTAssertFalse(cooking.contains("Tap as you prep"))
        XCTAssertFalse(cooking.contains("Text(\"Cooking\")"))
    }

    func testFocusActionUsesSignalColorWithReadableText() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Ladle/Cooking/FocusModeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains(
                ".foregroundStyle(LadleTheme.onAccent)"
            )
        )
        XCTAssertTrue(source.contains("LadleTheme.focusAccent"))
    }

    func testRuntimeConfigurationUsesInMemoryStoreForUnitTests() {
        let configuration = LadleRuntimeConfiguration(
            launchArguments: [],
            environment: [
                "XCTestConfigurationFilePath": "/tmp/LadleTests.xctestconfiguration",
            ]
        )

        XCTAssertTrue(configuration.usesInMemoryStore)
        XCTAssertTrue(configuration.seedsPreviewData)
    }

    func testRuntimeConfigurationKeepsProductionStorePersistent() {
        let configuration = LadleRuntimeConfiguration(
            launchArguments: [],
            environment: [:]
        )

        XCTAssertFalse(configuration.usesInMemoryStore)
        XCTAssertFalse(configuration.seedsPreviewData)
        XCTAssertTrue(configuration.usesAppAttest)
    }

    func testRuntimeConfigurationCanDisableAppAttestForDeviceBuild() {
        let configuration = LadleRuntimeConfiguration(
            launchArguments: [],
            environment: [:],
            infoDictionary: ["LadleAppAttestEnabled": "NO"]
        )

        XCTAssertFalse(configuration.usesAppAttest)
    }

    func testRuntimeConfigurationReadsOptionalTunnelAccessKey() {
        let configuration = LadleRuntimeConfiguration(
            launchArguments: [],
            environment: [:],
            infoDictionary: ["LadleTunnelAccessKey": "device-tunnel"]
        )

        XCTAssertEqual(configuration.tunnelAccessKey, "device-tunnel")
    }

    func testReleaseBuildTargetsGuardedVPS() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = try String(
            contentsOf: project.appendingPathComponent(
                "Config/Release.xcconfig"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            configuration.contains(
                "LADLE_API_BASE_URL = https:/$()/vps-8b0be574.vps.ovh.us"
            )
        )
        XCTAssertTrue(
            configuration.contains("LADLE_APP_ATTEST_ENABLED = NO")
        )
        XCTAssertTrue(
            configuration.contains(
                #"#include? "../.private/VPSRelease.xcconfig""#
            )
        )
    }

    func testGeneratedProjectKeepsAutomaticSigningTeam() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let specification = try String(
            contentsOf: project.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        XCTAssertTrue(specification.contains("DEVELOPMENT_TEAM: P48VDW72LU"))
        XCTAssertTrue(specification.contains("CODE_SIGN_STYLE: Automatic"))
    }

    func testRuntimeConfigurationReadsSharedKeychainAccessGroup() {
        let configuration = LadleRuntimeConfiguration(
            launchArguments: [],
            environment: [:],
            infoDictionary: [
                "LadleSharedKeychainAccessGroup":
                    "TEAM.com.ladle.shared",
            ]
        )

        XCTAssertEqual(
            configuration.sharedKeychainAccessGroup,
            "TEAM.com.ladle.shared"
        )
    }

    func testRuntimeConfigurationCanLaunchAnEmptyTestLibrary() {
        let configuration = LadleRuntimeConfiguration(
            launchArguments: ["-ui-testing", "-empty-library"],
            environment: [:]
        )

        XCTAssertTrue(configuration.usesInMemoryStore)
        XCTAssertFalse(configuration.seedsPreviewData)
    }

    func testGoogleAppCheckPrewarmFailureDoesNotBlockSignInSetup() async throws {
        let provider = GoogleSignInProvider(
            infoDictionary: [
                "GIDClientID": "ios-client-id",
                "GIDServerClientID": "server-client-id",
            ],
            configureAppCheck: { completion in
                completion(GoogleAppCheckTestError.unavailable)
            }
        )

        try await provider.configureIfNeeded()
    }

    func testAccountPresentationExplainsProviderAndSyncScope() {
        XCTAssertEqual(
            AccountSheet.accountTitle(for: .signedInWithGoogle),
            "Signed in with Google"
        )
        XCTAssertEqual(
            AccountSheet.accountDetail(for: .signedInWithGoogle),
            "Your recipes stay synced across your devices."
        )
        XCTAssertEqual(
            AccountSheet.syncValue(for: .signedInWithGoogle),
            "On"
        )
        XCTAssertEqual(
            AccountSheet.syncValue(for: .guest),
            "This device"
        )
    }

    func testLaunchScreenUsesThePaperSurface() {
        let launchScreen = Bundle.main.object(
            forInfoDictionaryKey: "UILaunchScreen"
        ) as? [String: Any]

        XCTAssertEqual(
            launchScreen?["UIColorName"] as? String,
            "Paper"
        )
    }

    func testPrivacyManifestDeclaresUserDefaultsReason() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(
                forResource: "PrivacyInfo",
                withExtension: "xcprivacy"
            )
        )
        let data = try Data(contentsOf: url)
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: Any]
        )
        let accessedTypes = try XCTUnwrap(
            manifest["NSPrivacyAccessedAPITypes"]
                as? [[String: Any]]
        )
        let userDefaults = try XCTUnwrap(
            accessedTypes.first {
                $0["NSPrivacyAccessedAPIType"] as? String
                    == "NSPrivacyAccessedAPICategoryUserDefaults"
            }
        )

        XCTAssertEqual(
            userDefaults["NSPrivacyAccessedAPITypeReasons"] as? [String],
            ["CA92.1"]
        )
    }

    func testReleaseVersionAndBuildAreAvailableAtRuntime() {
        XCTAssertEqual(
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            "1.0"
        )
        XCTAssertEqual(
            Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String,
            "20260825.2"
        )
    }

    func testRootViewCanBeCreated() throws {
        let environment = try AppEnvironment(isStoredInMemoryOnly: true)
        let accountSession = AccountSession()
        _ = RootView(
            accountSession: accountSession,
            libraryViewModel: LibraryViewModel(
                repository: environment.recipeRepository
            ),
            importCoordinator: ImportCoordinator(
                repository: environment.recipeRepository,
                service: DemoImportService(),
                accountSession: accountSession
            )
        )
    }

    func testWelcomeOnlyScrollsForAccessibilityTextSizes() {
        XCTAssertFalse(
            WelcomeView.usesScrollingLayout(for: .large)
        )
        XCTAssertTrue(
            WelcomeView.usesScrollingLayout(for: .accessibility1)
        )
    }

    func testImportFailuresExplainTheRecoveryPathInTheInbox() {
        XCTAssertEqual(
            ImportFailure.parserUnavailable.importInboxMessage,
            "Couldn’t read the video. Open for recovery options."
        )
        XCTAssertEqual(
            ImportFailure.networkUnavailable.importInboxMessage,
            "Connection interrupted. Open to retry."
        )
        XCTAssertEqual(
            ImportFailure.quotaExceeded.importInboxMessage,
            "Processing limit reached. Try again later."
        )
    }
}

private enum GoogleAppCheckTestError: Error {
    case unavailable
}
