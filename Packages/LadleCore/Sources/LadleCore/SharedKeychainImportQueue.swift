import Foundation
import Security

struct SharedKeychainRecord {
    let account: String
    let data: Data
}

protocol SharedKeychainDataStoring: AnyObject {
    func records(
        service: String,
        accessGroup: String
    ) throws -> [SharedKeychainRecord]

    func add(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String
    ) throws

    func delete(
        service: String,
        account: String,
        accessGroup: String
    ) throws
}

public final class SharedKeychainImportQueue: SharedImportQueueing {
    static let service = "com.ladle.ios.shared-imports"

    private let accessGroup: String
    private let store: any SharedKeychainDataStoring
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public convenience init(accessGroup: String) {
        self.init(
            accessGroup: accessGroup,
            store: SystemSharedKeychainDataStore()
        )
    }

    init(
        accessGroup: String,
        store: any SharedKeychainDataStoring
    ) {
        self.accessGroup = accessGroup
        self.store = store
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public func enqueue(_ envelope: SharedImportEnvelope) throws {
        let account = account(for: envelope.id)
        if let existing = try store.records(
            service: Self.service,
            accessGroup: accessGroup
        ).first(where: { $0.account == account }) {
            guard
                let queued = try? decoder.decode(
                    SharedImportEnvelope.self,
                    from: existing.data
                ),
                queued == envelope
            else {
                throw SharedImportQueueError.duplicateEnvelopeID(envelope.id)
            }
            return
        }

        try store.add(
            encoder.encode(envelope),
            service: Self.service,
            account: account,
            accessGroup: accessGroup
        )
    }

    public func pendingEnvelopes() throws -> [SharedImportEnvelope] {
        var envelopes: [SharedImportEnvelope] = []
        for record in try store.records(
            service: Self.service,
            accessGroup: accessGroup
        ) {
            do {
                let envelope = try decoder.decode(
                    SharedImportEnvelope.self,
                    from: record.data
                )
                guard record.account == account(for: envelope.id) else {
                    throw SharedKeychainRecordError.identifierMismatch
                }
                envelopes.append(envelope)
            } catch {
                try store.delete(
                    service: Self.service,
                    account: record.account,
                    accessGroup: accessGroup
                )
            }
        }
        return envelopes.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    @discardableResult
    public func dequeue(id: UUID) throws -> SharedImportEnvelope? {
        let account = account(for: id)
        guard
            let record = try store.records(
                service: Self.service,
                accessGroup: accessGroup
            ).first(where: { $0.account == account })
        else {
            return nil
        }

        let envelope = try? decoder.decode(
            SharedImportEnvelope.self,
            from: record.data
        )
        try store.delete(
            service: Self.service,
            account: account,
            accessGroup: accessGroup
        )
        return envelope
    }

    private func account(for id: UUID) -> String {
        id.uuidString.lowercased()
    }
}

private enum SharedKeychainRecordError: Error {
    case identifierMismatch
}

private enum SharedKeychainStoreError: Error {
    case unexpectedRecord
    case unexpectedStatus(OSStatus)
}

private final class SystemSharedKeychainDataStore:
    SharedKeychainDataStoring
{
    func records(
        service: String,
        accessGroup: String
    ) throws -> [SharedKeychainRecord] {
        var result: CFTypeRef?
        var query = baseQuery(
            service: service,
            accessGroup: accessGroup
        )
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw SharedKeychainStoreError.unexpectedStatus(status)
        }
        guard let items = result as? [[String: Any]] else {
            throw SharedKeychainStoreError.unexpectedRecord
        }
        return try items.map { item in
            guard
                let account = item[kSecAttrAccount as String] as? String,
                let data = item[kSecValueData as String] as? Data
            else {
                throw SharedKeychainStoreError.unexpectedRecord
            }
            return SharedKeychainRecord(account: account, data: data)
        }
    }

    func add(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String
    ) throws {
        var query = baseQuery(
            service: service,
            accessGroup: accessGroup
        )
        query[kSecAttrAccount as String] = account
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SharedKeychainStoreError.unexpectedStatus(status)
        }
    }

    func delete(
        service: String,
        account: String,
        accessGroup: String
    ) throws {
        var query = baseQuery(
            service: service,
            accessGroup: accessGroup
        )
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SharedKeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(
        service: String,
        accessGroup: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }
}
