import Foundation

protocol SyncCursorStoring: Sendable {
    func load() throws -> Int64
    func save(_ cursor: Int64) throws
    func reset() throws
}

final class SyncCursorStore: SyncCursorStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        key: String = "ladle.sync.cursor"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> Int64 {
        lock.withLock {
            guard defaults.object(forKey: key) != nil else {
                return 0
            }
            return Int64(defaults.integer(forKey: key))
        }
    }

    func save(_ cursor: Int64) throws {
        lock.withLock {
            defaults.set(cursor, forKey: key)
        }
    }

    func reset() throws {
        lock.withLock {
            defaults.removeObject(forKey: key)
        }
    }
}
