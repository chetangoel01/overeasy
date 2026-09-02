import Foundation
import Security

struct AuthTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let accessTokenExpiresAt: Date
    let refreshToken: String?
    let userID: UUID
    let deviceID: UUID
    let userKind: String
    /// The cook's profile as the server last reported it. It rides on the
    /// tokens rather than behind a `/me` call, so every refresh keeps it
    /// current, and it survives a relaunch because this record is also the
    /// Keychain record. Both fields are optional on the wire and absent
    /// from tokens saved by builds that predate them, so both decode as
    /// nil rather than failing the session.
    ///
    /// `avatarURL`, not `avatarUrl`: the backend's wire alias rewrites a
    /// trailing `Url` to `URL`, the same shape as `userID` above.
    var displayName: String?
    var avatarURL: URL?
    /// Whether that URL is the cook's own photo. `Bool?` rather than `Bool`
    /// for the same reason the fields around it are optional, and it matters
    /// more here: this record is decoded from the Keychain on every launch,
    /// and a non-optional flag would fail to decode every session written
    /// before the field existed — signing out every cook on upgrade.
    var avatarIsCustom: Bool?
    /// When the account was created. Optional for the same reason the two
    /// above are: a Keychain record written before the field existed decodes
    /// as nil rather than failing the session. The server always sends it.
    var createdAt: Date?

    init(
        accessToken: String,
        accessTokenExpiresAt: Date,
        refreshToken: String?,
        userID: UUID,
        deviceID: UUID,
        userKind: String,
        displayName: String? = nil,
        avatarURL: URL? = nil,
        avatarIsCustom: Bool? = nil,
        createdAt: Date? = nil
    ) {
        self.accessToken = accessToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshToken = refreshToken
        self.userID = userID
        self.deviceID = deviceID
        self.userKind = userKind
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.avatarIsCustom = avatarIsCustom
        self.createdAt = createdAt
    }

    /// Nil only when the account has nothing to say about itself at all —
    /// tokens from a build that predates these fields.
    var profile: AccountProfile? {
        AccountProfile(
            displayName: displayName,
            avatarURL: avatarURL,
            avatarIsCustom: avatarIsCustom ?? false,
            createdAt: createdAt
        )
        .nonEmpty
    }
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
