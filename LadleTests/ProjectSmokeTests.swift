import XCTest
@testable import Ladle

@MainActor
final class ProjectSmokeTests: XCTestCase {
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
}
