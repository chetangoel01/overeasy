import Foundation

public enum SharedImportQueueError: Error, Equatable {
    case duplicateEnvelopeID(UUID)
}

public final class SharedImportQueue {
    public static let appGroupIdentifier = "group.com.ladle.ios"
    public static let appGroupDirectoryName = "SharedImports"

    public let pendingDirectoryURL: URL
    public let quarantineDirectoryURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) {
        pendingDirectoryURL = directoryURL.appendingPathComponent(
            "Pending",
            isDirectory: true
        )
        quarantineDirectoryURL = directoryURL.appendingPathComponent(
            "Quarantine",
            isDirectory: true
        )
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        decoder = JSONDecoder()
    }

    public func enqueue(_ envelope: SharedImportEnvelope) throws {
        try prepareDirectories()
        let destination = recordURL(for: envelope.id)

        if fileManager.fileExists(atPath: destination.path) {
            do {
                let queued = try decodeEnvelope(at: destination)
                guard queued != envelope else {
                    return
                }
                throw SharedImportQueueError.duplicateEnvelopeID(envelope.id)
            } catch let queueError as SharedImportQueueError {
                throw queueError
            } catch {
                try quarantine(destination)
            }
        }

        let data = try encoder.encode(envelope)
        try data.write(to: destination, options: [.atomic])
    }

    public func pendingEnvelopes() throws -> [SharedImportEnvelope] {
        try prepareDirectories()
        let recordURLs = try fileManager.contentsOfDirectory(
            at: pendingDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "json" }

        var envelopes: [SharedImportEnvelope] = []
        for recordURL in recordURLs {
            do {
                let envelope = try decodeEnvelope(at: recordURL)
                let expectedFileName = self.recordURL(
                    for: envelope.id
                ).lastPathComponent
                guard recordURL.lastPathComponent == expectedFileName else {
                    throw SharedImportRecordError.identifierMismatch
                }
                envelopes.append(envelope)
            } catch {
                if fileManager.fileExists(atPath: recordURL.path) {
                    try quarantine(recordURL)
                }
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
        try prepareDirectories()
        let recordURL = recordURL(for: id)
        guard fileManager.fileExists(atPath: recordURL.path) else {
            return nil
        }

        let envelope: SharedImportEnvelope
        do {
            envelope = try decodeEnvelope(at: recordURL)
        } catch {
            if fileManager.fileExists(atPath: recordURL.path) {
                try quarantine(recordURL)
            }
            return nil
        }

        try fileManager.removeItem(at: recordURL)
        return envelope
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(
            at: pendingDirectoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: quarantineDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func recordURL(for id: UUID) -> URL {
        pendingDirectoryURL
            .appendingPathComponent(id.uuidString.lowercased())
            .appendingPathExtension("json")
    }

    private func decodeEnvelope(
        at recordURL: URL
    ) throws -> SharedImportEnvelope {
        let data = try Data(contentsOf: recordURL)
        return try decoder.decode(SharedImportEnvelope.self, from: data)
    }

    private func quarantine(_ recordURL: URL) throws {
        let baseName = recordURL.deletingPathExtension().lastPathComponent
        var destination = quarantineDirectoryURL
            .appendingPathComponent(baseName)
            .appendingPathExtension("json")
        if fileManager.fileExists(atPath: destination.path) {
            destination = quarantineDirectoryURL
                .appendingPathComponent(
                    "\(baseName)-\(UUID().uuidString.lowercased())"
                )
                .appendingPathExtension("json")
        }
        try fileManager.moveItem(at: recordURL, to: destination)
    }
}

private enum SharedImportRecordError: Error {
    case identifierMismatch
}
