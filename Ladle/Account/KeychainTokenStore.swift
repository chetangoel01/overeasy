import Foundation
import Security

struct AuthTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let accessTokenExpiresAt: Date
    let refreshToken: String?
    let userID: UUID
    let deviceID: UUID
    let userKind: String
}

protocol AuthTokenStoring: Sendable {
    func load() throws -> AuthTokens?
    func save(_ tokens: AuthTokens) throws
    func clear() throws
}

protocol SecureDataStoring: AnyObject {
    func read(service: String, account: String) throws -> Data?
    func write(_ data: Data, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

enum KeychainStoreError: Error {
    case unexpectedStatus(OSStatus)
}

final class SystemKeychainDataStore: SecureDataStoring {
    func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        return result as? Data
    }

    func write(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }
        var inserted = query
        inserted[kSecValueData as String] = data
        inserted[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(inserted as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(
            baseQuery(service: service, account: account) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(
        service: String,
        account: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class KeychainTokenStore: AuthTokenStoring, @unchecked Sendable {
    private let service: String
    private let account: String
    private let secureStore: any SecureDataStoring

    init(
        service: String = "com.ladle.ios.auth",
        account: String = "session",
        secureStore: any SecureDataStoring = SystemKeychainDataStore()
    ) {
        self.service = service
        self.account = account
        self.secureStore = secureStore
    }

    func load() throws -> AuthTokens? {
        guard let data = try secureStore.read(
            service: service,
            account: account
        ) else {
            return nil
        }
        return try PropertyListDecoder().decode(AuthTokens.self, from: data)
    }

    func save(_ tokens: AuthTokens) throws {
        let data = try PropertyListEncoder().encode(tokens)
        try secureStore.write(
            data,
            service: service,
            account: account
        )
    }

    func clear() throws {
        try secureStore.delete(service: service, account: account)
    }
}
