import LadleCore

enum ImportServiceProgress: Equatable, Sendable {
    case parsing
    case ready(Recipe)
    case needsReview(Recipe)
    case failed(ImportFailure)
}

struct ImportServiceUpdate: Equatable, Sendable {
    let remoteJobID: String
    let progress: ImportServiceProgress
    let serverRevision: Int?

    init(
        remoteJobID: String,
        progress: ImportServiceProgress,
        serverRevision: Int? = nil
    ) {
        self.remoteJobID = remoteJobID
        self.progress = progress
        self.serverRevision = serverRevision
    }
}

protocol ImportService: Sendable {
    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate

    func status(
        remoteJobID: String
    ) async throws -> ImportServiceUpdate

    func retry(
        remoteJobID: String,
        correctionNotes: String?,
        pastedRecipeText: String?
    ) async throws -> ImportServiceUpdate

    func cancel(remoteJobID: String) async throws
}

extension ImportService {
    func cancel(remoteJobID: String) async throws {}
}
