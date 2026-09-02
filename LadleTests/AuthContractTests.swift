import LadleCore
import XCTest
@testable import Ladle

/// The auth responses the app actually decodes, held to the golden fixtures
/// the backend re-emits byte for byte in `tests/contracts/`.
///
/// `AuthTokens` lives in the app rather than in LadleCore, so LadleCore's
/// `RemoteContractTests` can only check the shape; this is the check that the
/// type the Keychain stores and the session reads survives the wire.
final class AuthContractTests: XCTestCase {
    func testTokenFixtureDecodesWithTheProfileAndCreationDate() throws {
        let tokens: AuthTokens = try decodeFixture("auth-tokens")

        XCTAssertEqual(tokens.userKind, "google")
        XCTAssertEqual(tokens.displayName, "Priya Raman")
        XCTAssertEqual(
            tokens.avatarURL?.host,
            "images.ladle.example"
        )
        XCTAssertEqual(
            tokens.createdAt,
            ISO8601DateFormatter().date(from: "2026-08-14T12:00:00Z")
        )
        XCTAssertEqual(tokens.profile?.createdAt, tokens.createdAt)
    }

    /// The Keychain record is this same value re-encoded as a property list,
    /// so a date that decodes off the wire but does not survive storage would
    /// lose "cooking since" on the next launch and nowhere else.
    func testTokensSurviveTheKeychainRoundTrip() throws {
        let tokens: AuthTokens = try decodeFixture("auth-tokens")
        let store = KeychainTokenStore(
            secureStore: InMemorySecureDataStore()
        )

        try store.save(tokens)

        XCTAssertEqual(try store.load(), tokens)
    }

    /// Tokens written before the field existed still open. The profile they
    /// carry is not nil for want of a date — the name and avatar are the
    /// reason it exists — it simply has no month to print.
    func testTokensWithoutACreationDateStillDecode() throws {
        let legacy = Data(
            """
            {
              "accessToken": "access",
              "accessTokenExpiresAt": "2026-09-02T09:56:00.000Z",
              "refreshToken": null,
              "userID": "40000000-0000-4000-8000-000000000001",
              "deviceID": "50000000-0000-4000-8000-000000000001",
              "userKind": "apple",
              "displayName": "Priya Raman"
            }
            """.utf8
        )

        let tokens = try RemoteContractJSON.decoder().decode(
            AuthTokens.self,
            from: legacy
        )

        XCTAssertNil(tokens.createdAt)
        XCTAssertEqual(tokens.profile?.displayName, "Priya Raman")
        XCTAssertNil(tokens.profile?.createdAt)
    }

    /// A guest has no name and no avatar, and used to have no profile at all
    /// as a result. It now has a creation date, so the guest facts line has
    /// something to read — and nothing keyed off `profile == nil` may treat
    /// that as being signed in.
    func testAGuestProfileIsCarriedByItsCreationDateAlone() {
        let tokens = AuthTokens(
            accessToken: "access",
            accessTokenExpiresAt: .now,
            refreshToken: nil,
            userID: UUID(),
            deviceID: UUID(),
            userKind: "guest",
            createdAt: Date(timeIntervalSince1970: 1_786_000_000)
        )

        XCTAssertNotNil(tokens.profile)
        XCTAssertNil(tokens.profile?.displayName)
        XCTAssertNil(tokens.profile?.monogram)
        XCTAssertNotNil(tokens.profile?.createdAt)
    }

    private func decodeFixture<Value: Decodable>(
        _ name: String
    ) throws -> Value {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: root
                .appendingPathComponent("Contracts/Fixtures")
                .appendingPathComponent("\(name).json")
        )
        return try RemoteContractJSON.decoder().decode(Value.self, from: data)
    }
}

private final class InMemorySecureDataStore: SecureDataStoring {
    private var values: [String: Data] = [:]

    func read(service: String, account: String) throws -> Data? {
        values["\(service)/\(account)"]
    }

    func write(_ data: Data, service: String, account: String) throws {
        values["\(service)/\(account)"] = data
    }

    func delete(service: String, account: String) throws {
        values.removeValue(forKey: "\(service)/\(account)")
    }
}
