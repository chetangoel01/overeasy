import Foundation
import Testing
@testable import LadleCore

@Suite("Shared Keychain import queue")
struct SharedKeychainImportQueueTests {
    @Test
    func sharesDurableEnvelopesAcrossQueueInstances() throws {
        let store = InMemorySharedKeychainStore()
        let writer = SharedKeychainImportQueue(
            accessGroup: "TEAM.com.ladle.shared",
            store: store
        )
        let reader = SharedKeychainImportQueue(
            accessGroup: "TEAM.com.ladle.shared",
            store: store
        )
        let envelope = makeEnvelope()

        try writer.enqueue(envelope)

        #expect(try reader.pendingEnvelopes() == [envelope])
        #expect(try reader.dequeue(id: envelope.id) == envelope)
        #expect(try writer.pendingEnvelopes().isEmpty)
    }

    @Test
    func duplicateEnvelopeIDIsIdempotentButCannotOverwriteContent() throws {
        let queue = makeQueue()
        let envelope = makeEnvelope()
        try queue.enqueue(envelope)
        try queue.enqueue(envelope)

        let conflicting = SharedImportEnvelope(
            id: envelope.id,
            sourceURL: URL(string: "https://youtu.be/different")!,
            createdAt: envelope.createdAt
        )

        #expect(
            throws: SharedImportQueueError.duplicateEnvelopeID(envelope.id)
        ) {
            try queue.enqueue(conflicting)
        }
        #expect(try queue.pendingEnvelopes() == [envelope])
    }

    @Test
    func malformedRecordsAreRemovedWithoutBlockingValidImports() throws {
        let store = InMemorySharedKeychainStore()
        let queue = SharedKeychainImportQueue(
            accessGroup: "TEAM.com.ladle.shared",
            store: store
        )
        let envelope = makeEnvelope()
        try queue.enqueue(envelope)
        try store.add(
            Data("not-json".utf8),
            service: SharedKeychainImportQueue.service,
            account: "malformed",
            accessGroup: "TEAM.com.ladle.shared"
        )

        #expect(try queue.pendingEnvelopes() == [envelope])
        #expect(store.records.count == 1)
    }

    private func makeQueue() -> SharedKeychainImportQueue {
        SharedKeychainImportQueue(
            accessGroup: "TEAM.com.ladle.shared",
            store: InMemorySharedKeychainStore()
        )
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
}

private final class InMemorySharedKeychainStore:
    SharedKeychainDataStoring
{
    var records: [SharedKeychainRecord] = []

    func records(
        service: String,
        accessGroup: String
    ) throws -> [SharedKeychainRecord] {
        records
    }

    func add(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String
    ) throws {
        records.append(
            SharedKeychainRecord(account: account, data: data)
        )
    }

    func delete(
        service: String,
        account: String,
        accessGroup: String
    ) throws {
        records.removeAll { $0.account == account }
    }
}
