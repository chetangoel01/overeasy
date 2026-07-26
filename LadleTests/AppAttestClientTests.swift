import CryptoKit
import Foundation
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
