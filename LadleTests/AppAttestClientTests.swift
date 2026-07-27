import CryptoKit
import Foundation
import LadleCore
import UIKit
import XCTest
@testable import Ladle

final class AppAttestClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testAttestsNewKeyThenBindsImportAssertionToExactBody() async throws {
        let requests = Locked<[URLRequest]>([])
        URLProtocolStub.install { request in
            requests.withValue { $0.append(request) }
            let body = try URLProtocolStub.bodyData(for: request)
            let value = try JSONSerialization.jsonObject(with: body)
                as? [String: Any]
            let purpose = value?["purpose"] as? String
            let response: [String: Any] = [
                "challengeID":
                    purpose == "guestCreation"
                    ? "10000000-0000-4000-8000-000000000001"
                    : "10000000-0000-4000-8000-000000000002",
                "challenge": Data("server-challenge".utf8)
                    .base64EncodedString(),
                "expiresAt": "2026-07-26T16:05:00.000Z",
                "requiresAttestation": purpose == "guestCreation",
            ]
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(withJSONObject: response)
            )
        }
        let platform = FakeAppAttestPlatform()
        let secureStore = AppAttestMemoryStore()
        let client = AppAttestClient(
            baseURL: URL(string: "https://api.ladle.test")!,
            installationID: "installation-1",
            session: URLProtocolStub.session(),
            platform: platform,
            secureStore: secureStore
        )

        let evidence = try await client.guestEvidence()

        XCTAssertEqual(evidence?.kind.rawValue, "attestation")
        XCTAssertEqual(evidence?.keyID, "device-key")
        XCTAssertEqual(
            evidence?.attestationObject,
            Data("attestation-object".utf8).base64EncodedString()
        )
        XCTAssertEqual(
            platform.attestationHash,
            Data(SHA256.hash(data: Data("server-challenge".utf8)))
        )

        var importRequest = URLRequest(
            url: URL(string: "https://api.ladle.test/v1/imports")!
        )
        importRequest.httpMethod = "POST"
        importRequest.httpBody = Data(#"{"jobID":"job-1"}"#.utf8)
        let authorized = try await client.authorize(
            importRequest,
            purpose: .importSubmission
        )

        XCTAssertEqual(
            authorized.value(forHTTPHeaderField: "X-App-Attest-Kind"),
            "assertion"
        )
        let encodedClientData = try XCTUnwrap(
            authorized.value(
                forHTTPHeaderField: "X-App-Attest-Client-Data"
            )
        )
        let clientData = try XCTUnwrap(
            Data(base64Encoded: encodedClientData)
        )
        let binding = try JSONSerialization.jsonObject(with: clientData)
            as? [String: Any]
        XCTAssertEqual(binding?["installationID"] as? String, "installation-1")
        XCTAssertEqual(binding?["path"] as? String, "/v1/imports")
        XCTAssertEqual(
            binding?["bodySHA256"] as? String,
            SHA256.hash(data: importRequest.httpBody!)
                .map { String(format: "%02x", $0) }
                .joined()
        )
        XCTAssertEqual(requests.snapshot.count, 2)
    }

    @MainActor
    func testLiveRealDeviceEnforcesBindingReplayRevocationAndRotation() async throws {
        #if !LADLE_LIVE_APP_ATTEST
            throw XCTSkip(
                "Enable with OTHER_SWIFT_FLAGS=-DLADLE_LIVE_APP_ATTEST."
            )
        #elseif targetEnvironment(simulator)
            throw XCTSkip("Live App Attest requires a physical iOS device.")
        #else
            let baseURL = try APIConfiguration().baseURL
            XCTAssertEqual(baseURL.scheme, "https")
            let deviceID = try XCTUnwrap(
                UIDevice.current.identifierForVendor
            )
            let installationID =
                "live-app-attest-\(deviceID.uuidString.lowercased())"
            let keychainService = "com.ladle.ios.live-app-attest-tests"
            let tokenStore = InMemoryAuthTokenStore()
            let client = AppAttestClient(
                baseURL: baseURL,
                installationID: installationID,
                secureStore: SystemKeychainDataStore(),
                keychainService: keychainService,
                keychainAccount: "key-id"
            )

            try? await client.reset()
            var currentTokens: AuthTokens?
            do {
                let initialEvidenceValue = try await client.guestEvidence()
                let initialEvidence = try XCTUnwrap(initialEvidenceValue)
                let wrongInstallation = try await Self.createGuest(
                    baseURL: baseURL,
                    installationID: "\(installationID)-wrong",
                    evidence: initialEvidence
                )
                XCTAssertEqual(wrongInstallation.response.statusCode, 403)

                let initialGuest = try await Self.createGuest(
                    baseURL: baseURL,
                    installationID: installationID,
                    evidence: initialEvidence
                )
                XCTAssertEqual(initialGuest.response.statusCode, 201)
                var tokens = try RemoteContractJSON.decoder().decode(
                    AuthTokens.self,
                    from: initialGuest.data
                )
                try tokenStore.save(tokens)
                currentTokens = tokens

                let accepted = try await Self.authorizedUnsupportedImport(
                    baseURL: baseURL,
                    installationID: installationID,
                    accessToken: tokens.accessToken,
                    client: client
                )
                let first = try await URLSession.shared.data(
                    for: accepted
                )
                XCTAssertEqual(
                    try XCTUnwrap(first.1 as? HTTPURLResponse).statusCode,
                    422
                )
                let replay = try await URLSession.shared.data(
                    for: accepted
                )
                XCTAssertEqual(
                    try XCTUnwrap(replay.1 as? HTTPURLResponse).statusCode,
                    403
                )

                var invalid = try await Self.authorizedUnsupportedImport(
                    baseURL: baseURL,
                    installationID: installationID,
                    accessToken: tokens.accessToken,
                    client: client
                )
                invalid.setValue(
                    Data("invalid-assertion".utf8).base64EncodedString(),
                    forHTTPHeaderField: "X-App-Attest-Assertion"
                )
                let rejected = try await URLSession.shared.data(
                    for: invalid
                )
                XCTAssertEqual(
                    try XCTUnwrap(rejected.1 as? HTTPURLResponse).statusCode,
                    403
                )

                do {
                    _ = try await Self.authorizedUnsupportedImport(
                        baseURL: baseURL,
                        installationID: installationID,
                        accessToken: tokens.accessToken,
                        client: client
                    )
                    XCTFail("A revoked key must require fresh attestation.")
                } catch AppAttestClientError.keyRequiresAttestation {
                    // Expected: the invalid assertion revoked the device key.
                }

                try await client.reset()
                let rotatedEvidenceValue = try await client.guestEvidence()
                let rotatedEvidence = try XCTUnwrap(rotatedEvidenceValue)
                let rotatedGuest = try await Self.createGuest(
                    baseURL: baseURL,
                    installationID: installationID,
                    evidence: rotatedEvidence
                )
                XCTAssertEqual(rotatedGuest.response.statusCode, 201)
                tokens = try RemoteContractJSON.decoder().decode(
                    AuthTokens.self,
                    from: rotatedGuest.data
                )
                try tokenStore.save(tokens)
                currentTokens = tokens

                try await Self.deleteAccount(
                    baseURL: baseURL,
                    tokens: tokens
                )
                currentTokens = nil
                try await client.reset()
            } catch {
                if let currentTokens {
                    try? await Self.deleteAccount(
                        baseURL: baseURL,
                        tokens: currentTokens
                    )
                }
                try? await client.reset()
                throw error
            }
        #endif
    }

    private static func createGuest(
        baseURL: URL,
        installationID: String,
        evidence: AppAttestEvidence
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let body = try RemoteContractJSON.encode(
            LiveGuestRequest(
                installationID: installationID,
                attestation: evidence
            )
        )
        var request = URLRequest(
            url: baseURL.appending(path: "/v1/auth/guest")
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        let (data, rawResponse) = try await URLSession.shared.data(
            for: request
        )
        return (
            data,
            try XCTUnwrap(rawResponse as? HTTPURLResponse)
        )
    }

    private static func authorizedUnsupportedImport(
        baseURL: URL,
        installationID: String,
        accessToken: String,
        client: AppAttestClient
    ) async throws -> URLRequest {
        var request = URLRequest(
            url: baseURL.appending(path: "/v1/imports")
        )
        request.httpMethod = "POST"
        request.httpBody = try RemoteContractJSON.encode(
            LiveImportRequest(
                jobID: UUID(),
                sourceURL: URL(string: "https://example.com/recipe")!,
                allowDuplicate: false,
                idempotencyKey: UUID().uuidString.lowercased()
            )
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        return try await client.authorize(
            request,
            purpose: .importSubmission
        )
    }

    private static func deleteAccount(
        baseURL: URL,
        tokens: AuthTokens
    ) async throws {
        let refreshToken = try XCTUnwrap(tokens.refreshToken)
        let userID = tokens.userID.uuidString.lowercased()
        var request = URLRequest(
            url: baseURL.appending(path: "/v1/auth/account")
        )
        request.httpMethod = "DELETE"
        request.httpBody = try RemoteContractJSON.encode(
            LiveAccountDeletionRequest(
                confirmation: "DELETE",
                refreshToken: refreshToken,
                idempotencyKey: "live-attest-delete-\(userID)"
            )
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "Bearer \(tokens.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        let (_, rawResponse) = try await URLSession.shared.data(
            for: request
        )
        XCTAssertEqual(
            try XCTUnwrap(rawResponse as? HTTPURLResponse).statusCode,
            204
        )
    }
}

private struct LiveGuestRequest: Encodable, Sendable {
    let installationID: String
    let attestation: AppAttestEvidence
}

private struct LiveImportRequest: Encodable, Sendable {
    let jobID: UUID
    let sourceURL: URL
    let allowDuplicate: Bool
    let idempotencyKey: String
}

private struct LiveAccountDeletionRequest: Encodable, Sendable {
    let confirmation: String
    let refreshToken: String
    let idempotencyKey: String
}

private final class FakeAppAttestPlatform:
    AppAttestPlatformServing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedAttestationHash: Data?

    var isSupported: Bool { true }

    var attestationHash: Data? {
        lock.withLock { storedAttestationHash }
    }

    func generateKey() async throws -> String {
        "device-key"
    }

    func attestKey(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data {
        XCTAssertEqual(keyID, "device-key")
        lock.withLock {
            storedAttestationHash = clientDataHash
        }
        return Data("attestation-object".utf8)
    }

    func generateAssertion(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data {
        XCTAssertEqual(keyID, "device-key")
        XCTAssertEqual(clientDataHash.count, 32)
        return Data("assertion-object".utf8)
    }
}

private final class AppAttestMemoryStore:
    SecureDataStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(service: String, account: String) throws -> Data? {
        lock.withLock { values["\(service):\(account)"] }
    }

    func write(
        _ data: Data,
        service: String,
        account: String
    ) throws {
        lock.withLock {
            values["\(service):\(account)"] = data
        }
    }

    func delete(service: String, account: String) throws {
        _ = lock.withLock {
            values.removeValue(forKey: "\(service):\(account)")
        }
    }
}
