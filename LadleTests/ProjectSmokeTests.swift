import XCTest
import LadleCore
import SwiftUI
@testable import Ladle

@MainActor
final class ProjectSmokeTests: XCTestCase {
    func testLibraryUsesOneExclusiveWorkspaceDestination() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Ladle/Library/LibraryView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("LibraryWorkspaceDestination"))
        XCTAssertFalse(source.contains("isImportInboxPresented"))
        XCTAssertFalse(source.contains("isWatchPresented"))
        XCTAssertFalse(source.contains("isSearchPresented"))
    }

    func testPrimaryScreensAvoidRedundantExplanatoryHeadings() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let home = try String(
            contentsOf: project.appendingPathComponent(
                "Ladle/Library/LibraryHomeView.swift"
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

        XCTAssertFalse(home.contains("Return to saved recipe videos"))
        XCTAssertFalse(home.contains("Useful groups"))
        XCTAssertFalse(detail.contains("Text(kicker)"))
        XCTAssertFalse(cooking.contains("Tap as you prep"))
        XCTAssertFalse(cooking.contains("Text(\"Cooking\")"))
    }

    func testFocusActionUsesTextForItsFixedLightSurface() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Ladle/Cooking/FocusModeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains(
                ".foregroundStyle(LadleTheme.focusActionText)"
            )
        )
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
            "20260726.2"
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
