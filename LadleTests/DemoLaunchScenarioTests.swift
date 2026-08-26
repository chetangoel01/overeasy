import XCTest
@testable import Ladle

final class DemoLaunchScenarioTests: XCTestCase {
    func testEveryNamedScenarioParsesFromOneLaunchArgument() {
        let expected: [(String, DemoLaunchScenario)] = [
            ("empty", .empty),
            ("offline-content", .offlineContent),
            ("offline-empty", .offlineEmpty),
            ("store-failure", .storeFailure),
            ("discover-empty", .discoverEmpty),
            ("discover-rate-limited", .discoverRateLimited),
            ("import-quota", .importQuota),
            ("import-rate-limited", .importRateLimited),
            ("authentication-expired", .authenticationExpired),
            ("large-library", .largeLibrary),
        ]

        for (rawValue, scenario) in expected {
            XCTAssertEqual(
                DemoLaunchScenario(
                    launchArguments: ["-demo-scenario", rawValue]
                ),
                scenario
            )
        }
    }

    func testMissingUnknownOrContradictoryScenariosUseStandardDemo() {
        XCTAssertEqual(
            DemoLaunchScenario(launchArguments: []),
            .standard
        )
        XCTAssertEqual(
            DemoLaunchScenario(
                launchArguments: ["-demo-scenario", "not-a-scenario"]
            ),
            .standard
        )
        XCTAssertEqual(
            DemoLaunchScenario(
                launchArguments: [
                    "-demo-scenario", "empty",
                    "-demo-scenario", "offline-content",
                ]
            ),
            .standard
        )
    }

    func testLegacyEmptyLibraryArgumentRemainsSupported() {
        XCTAssertEqual(
            DemoLaunchScenario(launchArguments: ["-empty-library"]),
            .empty
        )
    }

    func testRuntimeIgnoresDemoScenariosOutsideExplicitUITesting() {
        let production = LadleRuntimeConfiguration(
            launchArguments: ["-demo-scenario", "offline-content"],
            environment: [:]
        )
        let demo = LadleRuntimeConfiguration(
            launchArguments: [
                "-ui-testing", "-demo-scenario", "offline-content",
            ],
            environment: [:]
        )

        XCTAssertEqual(production.demoScenario, .standard)
        XCTAssertEqual(demo.demoScenario, .offlineContent)
    }
}
