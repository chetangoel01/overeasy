import Foundation
import LadleCore

enum DemoLaunchScenario: String, CaseIterable {
    case standard
    case empty
    case offlineContent = "offline-content"
    case offlineEmpty = "offline-empty"
    case storeFailure = "store-failure"
    case discoverEmpty = "discover-empty"
    case discoverRateLimited = "discover-rate-limited"
    case importQuota = "import-quota"
    case importRateLimited = "import-rate-limited"
    case authenticationExpired = "authentication-expired"
    case largeLibrary = "large-library"

    private static let argument = "-demo-scenario"

    init(launchArguments: [String]) {
        let values = launchArguments.indices.compactMap { index -> String? in
            guard launchArguments[index] == Self.argument,
                  launchArguments.indices.contains(index + 1)
            else { return nil }
            return launchArguments[index + 1]
        }
        let usesLegacyEmpty = launchArguments.contains("-empty-library")

        if values.isEmpty, usesLegacyEmpty {
            self = .empty
        } else if values.count == 1,
                  !usesLegacyEmpty,
                  let scenario = Self(rawValue: values[0]) {
            self = scenario
        } else {
            self = .standard
        }
    }

    var seedsRecipes: Bool {
        switch self {
        case .empty, .offlineEmpty, .storeFailure:
            false
        default:
            true
        }
    }

    var recipes: [Recipe] {
        self == .largeLibrary
            ? PreviewFixtures.largeLibraryRecipes
            : PreviewFixtures.recipes
    }

    var syncFailure: APIError? {
        switch self {
        case .offlineContent, .offlineEmpty:
            .transport
        case .authenticationExpired:
            .authenticationExpired
        default:
            nil
        }
    }

    var importFailure: APIError? {
        switch self {
        case .importQuota:
            DemoRemoteError.quota
        case .importRateLimited:
            DemoRemoteError.rateLimited
        default:
            nil
        }
    }
}

enum DemoRemoteError {
    static let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let quota = make(code: .quotaExceeded)
    static let rateLimited = make(
        code: .rateLimited,
        retryAt: retryAt
    )

    private static func make(
        code: RemoteErrorCode,
        retryAt: Date? = nil
    ) -> APIError {
        var error: [String: Any] = [
            "code": code.rawValue,
            "message": "Deterministic demo failure.",
            "retryable": code == .rateLimited,
            "requestID": "00000000-0000-4000-8000-000000000001",
        ]
        if let retryAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            error["details"] = ["retryAt": formatter.string(from: retryAt)]
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: ["error": error]
            ),
            let envelope = try? RemoteContractJSON.decoder().decode(
                RemoteErrorEnvelope.self,
                from: data
            )
        else {
            return .invalidResponse
        }
        return .remote(envelope.error)
    }
}
