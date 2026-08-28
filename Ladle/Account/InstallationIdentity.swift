import Foundation

/// The device's installation identifier.
///
/// The backend binds this value to an account: `POST /v1/auth/guest` issues a
/// session for whatever user the matching device row points at. That makes it
/// a credential, so a real account signing out must rotate it — otherwise the
/// next guest registration on this device replays the signed-out account's
/// binding and hands over that library. A guest keeps its identifier, because
/// the binding is the only thing that account has.
///
/// The backing store must be safe to touch from any thread; `UserDefaults` is.
final class InstallationIdentity: @unchecked Sendable {
    static let storeKey = "ladle.installation.id"

    private let store: any PreferenceStoring
    private let lock = NSLock()

    init(store: any PreferenceStoring = UserDefaults.standard) {
        self.store = store
    }

    /// The current identifier, minted on first use.
    var current: String {
        lock.lock()
        defer { lock.unlock() }
        return store.string(forKey: Self.storeKey) ?? mint()
    }

    /// Discards the current identifier and mints a replacement.
    @discardableResult
    func rotate() -> String {
        lock.lock()
        defer { lock.unlock() }
        return mint()
    }

    /// Forgets the identifier so the next read mints a fresh one.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        store.removeObject(forKey: Self.storeKey)
    }

    private func mint() -> String {
        let created = UUID().uuidString.lowercased()
        store.set(created, forKey: Self.storeKey)
        return created
    }
}
