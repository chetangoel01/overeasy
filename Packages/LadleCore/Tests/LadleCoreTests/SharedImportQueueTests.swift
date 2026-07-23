import Foundation
import Testing
@testable import LadleCore

@Suite("Shared import queue")
struct SharedImportQueueTests {
    @Test
    func enqueueWritesOneAtomicRecordAndDequeueRemovesIt() throws {
        try withTemporaryQueue { queue in
            let envelope = makeEnvelope()

            try queue.enqueue(envelope)

            #expect(try queue.pendingEnvelopes() == [envelope])
            let files = try FileManager.default.contentsOfDirectory(
                at: queue.pendingDirectoryURL,
                includingPropertiesForKeys: nil
            )
            #expect(files.filter { $0.pathExtension == "json" }.count == 1)
            #expect(files.allSatisfy { $0.pathExtension != "tmp" })

            #expect(try queue.dequeue(id: envelope.id) == envelope)
            #expect(try queue.pendingEnvelopes().isEmpty)
        }
    }

    @Test
    func duplicateEnvelopeIDIsIdempotentButCannotOverwriteContent() throws {
        try withTemporaryQueue { queue in
            let envelope = makeEnvelope()
            try queue.enqueue(envelope)
            try queue.enqueue(envelope)

            #expect(try queue.pendingEnvelopes() == [envelope])

            let conflicting = SharedImportEnvelope(
                id: envelope.id,
                sourceURL: URL(
                    string: "https://www.youtube.com/watch?v=different"
                )!,
                createdAt: envelope.createdAt
            )
            #expect(
                throws: SharedImportQueueError.duplicateEnvelopeID(
                    envelope.id
                )
            ) {
                try queue.enqueue(conflicting)
            }
            #expect(try queue.pendingEnvelopes() == [envelope])
        }
    }

    @Test
    func malformedRecordIsQuarantinedWithoutBlockingValidImports() throws {
        try withTemporaryQueue { queue in
            let envelope = makeEnvelope()
            try queue.enqueue(envelope)
            let malformedURL = queue.pendingDirectoryURL
                .appendingPathComponent("malformed.json")
            try Data("not-json".utf8).write(to: malformedURL)

            #expect(try queue.pendingEnvelopes() == [envelope])
            #expect(!FileManager.default.fileExists(atPath: malformedURL.path))

            let quarantined = try FileManager.default
                .contentsOfDirectory(
                    at: queue.quarantineDirectoryURL,
                    includingPropertiesForKeys: nil
            )
            #expect(quarantined.count == 1)
            #expect(
                quarantined.first?.lastPathComponent
                    .hasPrefix("malformed") == true
            )
        }
    }

    @Test
    func mismatchedRecordNameIsQuarantined() throws {
        try withTemporaryQueue { queue in
            let envelope = makeEnvelope()
            _ = try queue.pendingEnvelopes()
            let wrongNameURL = queue.pendingDirectoryURL
                .appendingPathComponent("wrong-envelope-id.json")
            try JSONEncoder().encode(envelope).write(to: wrongNameURL)

            #expect(try queue.pendingEnvelopes().isEmpty)
            #expect(
                !FileManager.default.fileExists(
                    atPath: wrongNameURL.path
                )
            )
            let quarantined = try FileManager.default
                .contentsOfDirectory(
                    at: queue.quarantineDirectoryURL,
                    includingPropertiesForKeys: nil
                )
            #expect(quarantined.count == 1)
        }
    }

    @Test
    func interruptedTemporaryWriteCannotReplaceValidRecord() throws {
        try withTemporaryQueue { queue in
            let envelope = makeEnvelope()
            try queue.enqueue(envelope)
            let interruptedURL = queue.pendingDirectoryURL
                .appendingPathComponent(".\(envelope.id.uuidString).tmp")
            try Data("{\"id\":".utf8).write(to: interruptedURL)

            #expect(try queue.pendingEnvelopes() == [envelope])
            #expect(
                FileManager.default.fileExists(
                    atPath: interruptedURL.path
                )
            )
        }
    }

    private func makeEnvelope() -> SharedImportEnvelope {
        SharedImportEnvelope(
            id: UUID(
                uuidString: "90B95FC8-2D93-499D-8A85-60F577DC0A15"
            )!,
            sourceURL: URL(
                string: "https://www.instagram.com/reel/lemon-orzo"
            )!,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func withTemporaryQueue(
        _ body: (SharedImportQueue) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try body(SharedImportQueue(directoryURL: directory))
    }
}
