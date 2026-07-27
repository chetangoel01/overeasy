import Foundation
import LadleCore

@MainActor
final class SharedQueueReconciler {
    private let queue: any SharedImportQueueing
    private let repository: RecipeRepository

    init(
        queue: any SharedImportQueueing,
        repository: RecipeRepository
    ) {
        self.queue = queue
        self.repository = repository
    }

    @discardableResult
    func reconcile() throws -> Int {
        let envelopes = try queue.pendingEnvelopes()
        var knownJobIDs = Set(
            try repository.fetchImportJobs().map(\.id)
        )
        var importedCount = 0

        for envelope in envelopes {
            if knownJobIDs.contains(envelope.id) {
                try queue.dequeue(id: envelope.id)
                continue
            }

            let job = ImportJob.queued(
                sourceURL: envelope.sourceURL,
                source: source(for: envelope.sourceURL),
                id: envelope.id,
                createdAt: envelope.createdAt
            )
            try repository.save(job)
            knownJobIDs.insert(job.id)
            importedCount += 1
            try queue.dequeue(id: envelope.id)
        }

        return importedCount
    }

    private func source(for url: URL) -> RecipeSource {
        let host = url.host?.lowercased() ?? ""
        if host == "tiktok.com" || host.hasSuffix(".tiktok.com") {
            return .tiktok
        }
        if host == "instagram.com" || host.hasSuffix(".instagram.com") {
            return .instagram
        }
        if host == "youtube.com"
            || host.hasSuffix(".youtube.com")
            || host == "youtu.be"
            || host.hasSuffix(".youtu.be") {
            return .youtube
        }
        return .other
    }
}
