import CryptoKit
@preconcurrency import DeviceCheck
import Foundation
import LadleCore

enum AppAttestPurpose: String, Codable, Equatable, Sendable {
    case guestCreation
    case importSubmission
    case importRetry
}

enum AppAttestEvidenceKind: String, Codable, Sendable {
    case attestation
    case assertion
}

struct AppAttestEvidence: Codable, Sendable {
    let kind: AppAttestEvidenceKind
    let keyID: String
    let challengeID: UUID
    let challenge: String
    let attestationObject: String?
    let assertion: String?
    let clientData: String?
}

protocol AppAttesting: Sendable {
    func guestEvidence() async throws -> AppAttestEvidence?
    func authorize(
        _ request: URLRequest,
        purpose: AppAttestPurpose
    ) async throws -> URLRequest
    func reset() async throws
}

protocol AppAttestPlatformServing: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data
    func generateAssertion(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data
}

private final class SystemAppAttestPlatform:
    AppAttestPlatformServing,
    @unchecked Sendable
{
    private let service = DCAppAttestService.shared

    var isSupported: Bool {
        service.isSupported
    }

    func generateKey() async throws -> String {
        try await service.generateKey()
    }

    func attestKey(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data {
        try await service.attestKey(
            keyID,
            clientDataHash: clientDataHash
        )
    }

    func generateAssertion(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data {
        try await service.generateAssertion(
            keyID,
            clientDataHash: clientDataHash
        )
    }
}

enum AppAttestClientError: Error {
    case invalidChallenge
    case keyRequiresAttestation
    case serverRejected
}

actor AppAttestClient: AppAttesting {
    private struct ChallengeRequest: Encodable, Sendable {
        let installationID: String
        let purpose: AppAttestPurpose
        let keyID: String?
    }

    private struct ChallengeResponse: Decodable, Sendable {
        let challengeID: UUID
        let challenge: String
        let expiresAt: Date
        let requiresAttestation: Bool
    }

    private let baseURL: URL
    private let installationID: String
    private let session: URLSession
    private let platform: any AppAttestPlatformServing
    private let secureStore: any SecureDataStoring
    private let keychainService: String
    private let keychainAccount: String

    init(
        baseURL: URL,
        installationID: String,
        session: URLSession = .shared,
        platform: any AppAttestPlatformServing = SystemAppAttestPlatform(),
        secureStore: any SecureDataStoring = SystemKeychainDataStore(),
        keychainService: String = "com.ladle.ios.app-attest",
        keychainAccount: String = "key-id"
    ) {
        self.baseURL = baseURL
        self.installationID = installationID
        self.session = session
        self.platform = platform
        self.secureStore = secureStore
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    func guestEvidence() async throws -> AppAttestEvidence? {
        guard platform.isSupported else {
            return nil
        }
        let keyID = try await keyID()
        let challenge = try await issueChallenge(
            purpose: .guestCreation,
            keyID: keyID
        )
        guard let challengeData = Data(
            base64Encoded: challenge.challenge
        ) else {
            throw AppAttestClientError.invalidChallenge
        }
        if challenge.requiresAttestation {
            let object = try await platform.attestKey(
                keyID,
                clientDataHash: sha256(challengeData)
            )
            return AppAttestEvidence(
                kind: .attestation,
                keyID: keyID,
                challengeID: challenge.challengeID,
                challenge: challenge.challenge,
                attestationObject: object.base64EncodedString(),
                assertion: nil,
                clientData: nil
            )
        }
        return try await assertionEvidence(
            keyID: keyID,
            challenge: challenge,
            purpose: .guestCreation,
            method: "POST",
            path: "/v1/auth/guest",
            bodySHA256: nil
        )
    }

    func authorize(
        _ request: URLRequest,
        purpose: AppAttestPurpose
    ) async throws -> URLRequest {
        guard platform.isSupported else {
            return request
        }
        guard let keyID = try storedKeyID() else {
            throw AppAttestClientError.keyRequiresAttestation
        }
        let challenge = try await issueChallenge(
            purpose: purpose,
            keyID: keyID
        )
        guard !challenge.requiresAttestation else {
            throw AppAttestClientError.keyRequiresAttestation
        }
        let evidence = try await assertionEvidence(
            keyID: keyID,
            challenge: challenge,
            purpose: purpose,
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "/",
            bodySHA256: sha256Hex(request.httpBody ?? Data())
        )
        var authorized = request
        authorized.setValue(
            evidence.kind.rawValue,
            forHTTPHeaderField: "X-App-Attest-Kind"
        )
        authorized.setValue(
            evidence.keyID,
            forHTTPHeaderField: "X-App-Attest-Key-ID"
        )
        authorized.setValue(
            evidence.challengeID.uuidString.lowercased(),
            forHTTPHeaderField: "X-App-Attest-Challenge-ID"
        )
        authorized.setValue(
            evidence.challenge,
            forHTTPHeaderField: "X-App-Attest-Challenge"
        )
        authorized.setValue(
            evidence.assertion,
            forHTTPHeaderField: "X-App-Attest-Assertion"
        )
        authorized.setValue(
            evidence.clientData,
            forHTTPHeaderField: "X-App-Attest-Client-Data"
        )
        return authorized
    }

    func reset() async throws {
        try secureStore.delete(
            service: keychainService,
            account: keychainAccount
        )
    }

    private func assertionEvidence(
        keyID: String,
        challenge: ChallengeResponse,
        purpose: AppAttestPurpose,
        method: String,
        path: String,
        bodySHA256: String?
    ) async throws -> AppAttestEvidence {
        let clientData = try Self.clientData(
            challenge: challenge,
            installationID: installationID,
            purpose: purpose,
            method: method,
            path: path,
            bodySHA256: bodySHA256
        )
        let assertion = try await platform.generateAssertion(
            keyID,
            clientDataHash: sha256(clientData)
        )
        return AppAttestEvidence(
            kind: .assertion,
            keyID: keyID,
            challengeID: challenge.challengeID,
            challenge: challenge.challenge,
            attestationObject: nil,
            assertion: assertion.base64EncodedString(),
            clientData: clientData.base64EncodedString()
        )
    }

    private func issueChallenge(
        purpose: AppAttestPurpose,
        keyID: String
    ) async throws -> ChallengeResponse {
        let url = baseURL.appending(
            path: "/v1/attestation/challenges"
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.httpBody = try RemoteContractJSON.encode(
            ChallengeRequest(
                installationID: installationID,
                purpose: purpose,
                keyID: keyID
            )
        )
        let (data, rawResponse) = try await session.data(for: request)
        guard
            let response = rawResponse as? HTTPURLResponse,
            (200 ..< 300).contains(response.statusCode)
        else {
            throw AppAttestClientError.serverRejected
        }
        return try RemoteContractJSON.decoder().decode(
            ChallengeResponse.self,
            from: data
        )
    }

    private func keyID() async throws -> String {
        if let existing = try storedKeyID() {
            return existing
        }
        let created = try await platform.generateKey()
        try secureStore.write(
            Data(created.utf8),
            service: keychainService,
            account: keychainAccount
        )
        return created
    }

    private func storedKeyID() throws -> String? {
        guard
            let value = try secureStore.read(
                service: keychainService,
                account: keychainAccount
            ),
            let keyID = String(data: value, encoding: .utf8),
            !keyID.isEmpty
        else {
            return nil
        }
        return keyID
    }

    private static func clientData(
        challenge: ChallengeResponse,
        installationID: String,
        purpose: AppAttestPurpose,
        method: String,
        path: String,
        bodySHA256: String?
    ) throws -> Data {
        let value: [String: Any] = [
            "bodySHA256": bodySHA256 ?? NSNull(),
            "challenge": challenge.challenge,
            "challengeID": challenge.challengeID.uuidString.lowercased(),
            "installationID": installationID,
            "method": method.uppercased(),
            "path": path,
            "purpose": purpose.rawValue,
        ]
        return try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

private func sha256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
