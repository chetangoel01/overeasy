import Foundation

protocol SyncCursorStoring: Sendable {
    func load() throws -> Int64
    func save(_ cursor: Int64) throws
    func reset() throws
    /// Whether a pull from the beginning of the log has met a recipe that
    /// names its source. Recipes synced before the server sent `sourceID`
    /// learn it only from such a pull, and one made against a server that
    /// does not send it yet teaches nothing — so this records what was
    /// learned, not that a pull was tried.
    var hasLearnedSourceIDs: Bool { get }
    func markSourceIDsLearned()
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

    var hasLearnedSourceIDs: Bool {
        lock.withLock { defaults.bool(forKey: key + ".source-ids") }
    }

    func markSourceIDsLearned() {
        lock.withLock { defaults.set(true, forKey: key + ".source-ids") }
    }
}
