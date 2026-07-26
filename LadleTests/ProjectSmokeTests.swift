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
