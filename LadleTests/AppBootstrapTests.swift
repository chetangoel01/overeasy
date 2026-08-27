import XCTest
@testable import Ladle

@MainActor
final class AppBootstrapTests: XCTestCase {
    func testLocalStoreFailureProducesRecoverableDiagnostic() {
        let bootstrap = AppBootstrap(
            configuration: testConfiguration,
            makeEnvironment: { _ in
                throw BootstrapTestError.store
            },
            installationIdentity: InstallationIdentity(
                store: BootstrapMemoryPreferenceStore()
            )
        )

        guard case let .failed(failure) = bootstrap.run() else {
            return XCTFail("Expected bootstrap failure")
        }
        XCTAssertEqual(failure.kind, .localStore)
        XCTAssertEqual(failure.diagnosticIdentifier, "OE-BOOT-STORE-001")
        XCTAssertEqual(failure.actionTitle, "Retry")
        XCTAssertTrue(failure.message.contains("not replaced or cleared"))
    }

    func testInvalidAPIConfigurationProducesBlockingDiagnostic() throws {
        let bootstrap = AppBootstrap(
            configuration: productionConfiguration,
            makeEnvironment: { _ in
                try AppEnvironment(isStoredInMemoryOnly: true)
            },
            makeBaseURL: {
                throw BootstrapTestError.configuration
            },
            installationIdentity: InstallationIdentity(
                store: BootstrapMemoryPreferenceStore()
            )
        )

        guard case let .failed(failure) = bootstrap.run() else {
            return XCTFail("Expected configuration failure")
        }
        XCTAssertEqual(failure.kind, .invalidConfiguration)
        XCTAssertEqual(failure.diagnosticIdentifier, "OE-BOOT-CONFIG-001")
        XCTAssertNil(failure.actionTitle)
        XCTAssertTrue(failure.message.contains("Install a valid build"))
    }

    func testSuccessfulBootstrapProducesRuntimeDependencies() throws {
        var requestedBaseURL = false
        let bootstrap = AppBootstrap(
            configuration: testConfiguration,
            makeEnvironment: { _ in
                try AppEnvironment(isStoredInMemoryOnly: true)
            },
            makeBaseURL: {
                requestedBaseURL = true
                return URL(string: "https://example.com")!
            },
            installationIdentity: InstallationIdentity(
                store: BootstrapMemoryPreferenceStore()
            )
        )

        guard case let .ready(runtime) = bootstrap.run() else {
            return XCTFail("Expected ready runtime")
        }
        XCTAssertFalse(requestedBaseURL)
        XCTAssertNotNil(runtime.appEnvironment.modelContainer)
        XCTAssertNotNil(runtime.libraryViewModel)
        XCTAssertNotNil(runtime.importCoordinator)
        XCTAssertNil(runtime.authClient)
        XCTAssertNil(runtime.syncService)
        XCTAssertTrue(
            try runtime.appEnvironment.recipeRepository.fetchRecipes().isEmpty
        )
    }

    func testRetryCanRecoverAfterStoreCreationFailure() {
        var attempts = 0
        let bootstrap = AppBootstrap(
            configuration: testConfiguration,
            makeEnvironment: { _ in
                attempts += 1
                if attempts == 1 {
                    throw BootstrapTestError.store
                }
                return try AppEnvironment(isStoredInMemoryOnly: true)
            },
            installationIdentity: InstallationIdentity(
                store: BootstrapMemoryPreferenceStore()
            )
        )

        guard case .failed = bootstrap.run() else {
            return XCTFail("Expected first attempt to fail")
        }
        guard case .ready = bootstrap.run() else {
            return XCTFail("Expected retry to produce a runtime")
        }
        XCTAssertEqual(attempts, 2)
    }

    private var testConfiguration: LadleRuntimeConfiguration {
        LadleRuntimeConfiguration(
            launchArguments: ["-ui-testing", "-empty-library"],
            environment: [:]
        )
    }

    private var productionConfiguration: LadleRuntimeConfiguration {
        LadleRuntimeConfiguration(
            launchArguments: [],
            environment: [:]
        )
    }
}

private enum BootstrapTestError: Error {
    case store
    case configuration
}

private final class BootstrapMemoryPreferenceStore: PreferenceStoring {
    private var values: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}
