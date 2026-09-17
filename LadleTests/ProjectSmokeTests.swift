import XCTest
import LadleCore
import SwiftUI
import UIKit
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

    /// Also the only check the `@Sendable` completion needs: this closure
    /// would not compile against a non-`Sendable` parameter, which a retired
    /// test used to assert by searching the provider's source for the words.
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

    /// Icon switching requires every alternate name in the compiled bundle.
    func testEveryAlternateIconIsDeclaredInTheBundle() throws {
        let icons = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons")
                as? [String: Any]
        )
        let alternates = try XCTUnwrap(
            icons["CFBundleAlternateIcons"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(alternates.keys),
            Set(LadleAppIcon.allCases.compactMap(\.alternateIconName))
        )
        for icon in LadleAppIcon.allCases {
            if let name = icon.alternateIconName {
                let entry = try XCTUnwrap(alternates[name] as? [String: Any])
                XCTAssertEqual(entry["CFBundleIconName"] as? String, name)
            }
            XCTAssertNotNil(UIImage(named: icon.markImageName), icon.title)
        }
    }

    /// A flattened opaque foreground silently loses Liquid Glass depth and
    /// Clear appearance. Every option needs an independent background and
    /// transparent artwork, including the primary egg and legacy avocado name.
    func testEveryAppIconHasTransparentArtworkForLiquidGlass() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Ladle/Resources")

        for option in LadleAppIcon.allCases {
            let name = option.alternateIconName ?? "AppIcon"
            let package = resources.appendingPathComponent("AppIcons/\(name).icon")
            let document = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(contentsOf: package.appendingPathComponent("icon.json"))
                ) as? [String: Any], name
            )
            XCTAssertNotNil(document["fill"], "\(name) needs a separate background")
            let groups = try XCTUnwrap(document["groups"] as? [[String: Any]], name)
            let layers = groups.flatMap { $0["layers"] as? [[String: Any]] ?? [] }
            XCTAssertFalse(layers.isEmpty, name)

            for layer in layers {
                let filename = try XCTUnwrap(layer["image-name"] as? String, name)
                let data = try Data(contentsOf: package.appendingPathComponent("Assets/\(filename)"))
                let image = try XCTUnwrap(UIImage(data: data)?.cgImage, name)
                XCTAssertEqual(image.width, 1024, name)
                XCTAssertEqual(image.height, 1024, name)
                let context = try XCTUnwrap(CGContext(
                    data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                    bytesPerRow: 1024 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
                let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                let alpha = stride(from: 3, to: 1024 * 1024 * 4, by: 4).map { pixels[$0] }
                XCTAssertEqual(alpha[0], 0, "\(name) must leave its background transparent")
                XCTAssertTrue(alpha.contains { $0 > 240 }, "\(name) has no visible artwork")
            }

            let preview = try XCTUnwrap(UIImage(named: option.markImageName)?.cgImage, name)
            XCTAssertGreaterThanOrEqual(preview.width, 288, name)
            XCTAssertEqual(preview.width, preview.height, name)
        }
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
        // The build number is deliberately not pinned. It changes on every
        // upload — App Store Connect rejects one it has already seen — so a
        // literal here only ever fails late, and it did: the bump to
        // 20260902.1 for the first TestFlight build broke this test, and the
        // CI gate never ran it. What matters at runtime is that the value is
        // present and shaped like the date-plus-counter scheme
        // Tools/release/testflight.sh generates.
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        let unwrapped = try? XCTUnwrap(build)
        XCTAssertNotNil(unwrapped)
        XCTAssertEqual(
            unwrapped?.range(
                of: #"^\d{8}\.\d+$"#,
                options: .regularExpression
            ) != nil,
            true,
            "CFBundleVersion \(build ?? "nil") is not YYYYMMDD.N"
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

    func testAccountAuthenticationFailureDistinguishesOfflineAndCancellation() throws {
        let offline = try XCTUnwrap(
            AccountAuthenticationFailure(
                APIError.transport,
                fallback: "Account setup didn’t complete."
            )
        )

        XCTAssertEqual(
            offline,
            .remote(RemoteFailureReport(APIError.transport))
        )
        XCTAssertEqual(
            offline.message,
            "You’re offline. Reconnect and try again."
        )
        XCTAssertNil(
            AccountAuthenticationFailure(
                GoogleSignInProviderError.cancelled,
                fallback: "Sign-in failed."
            )
        )
        XCTAssertNil(
            AccountAuthenticationFailure(
                CancellationError(),
                fallback: "Sign-in failed."
            )
        )
    }

    func testAccountDeletionFailurePreservesRateLimitTiming() throws {
        let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
        let failure = AccountDeletionFailure(
            failure: .rateLimited(retryAt: retryAt)
        )

        XCTAssertEqual(failure.retryAt, retryAt)
        XCTAssertFalse(
            failure.canRetry(at: retryAt.addingTimeInterval(-1))
        )
        XCTAssertTrue(failure.canRetry(at: retryAt))
        XCTAssertTrue(failure.message.contains("Try again after"))
        XCTAssertNil(AccountDeletionFailure(CancellationError()))
    }
}

private enum GoogleAppCheckTestError: Error {
    case unavailable
}
