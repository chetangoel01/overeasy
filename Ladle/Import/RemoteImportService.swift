import Foundation
import LadleCore

struct RemoteImportService: ImportService {
    private struct SubmissionRequest: Encodable, Sendable {
        let jobID: UUID
        let sourceURL: URL
        let allowDuplicate: Bool
        let idempotencyKey: String
        let currentRecipeID: UUID?
        let correctionNotes: String?
        let pastedText: String?
    }

    private struct RetryRequest: Encodable, Sendable {
        let correctionNotes: String?
        let pastedText: String?
    }

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        let response: RemoteImportJobDTO = try await api.request(
            path: "/v1/imports",
            method: .post,
            body: SubmissionRequest(
                jobID: job.id,
                sourceURL: job.sourceURL,
                allowDuplicate: allowingDuplicate,
                idempotencyKey: job.id.uuidString.lowercased(),
                currentRecipeID: job.currentRecipeID,
                correctionNotes: job.correctionNotes,
                pastedText: job.pastedRecipeText
            ),
            appAttestPurpose: .importSubmission
        )
        return try await update(from: response)
    }

    func status(
        remoteJobID: String
    ) async throws -> ImportServiceUpdate {
        let jobID = try validatedJobID(remoteJobID)
        let response: RemoteImportJobDTO = try await api.request(
            path: "/v1/imports/\(jobID.uuidString)"
        )
        return try await update(from: response)
    }

    func retry(
        remoteJobID: String,
        correctionNotes: String?,
        pastedRecipeText: String?
    ) async throws -> ImportServiceUpdate {
        let jobID = try validatedJobID(remoteJobID)
        let response: RemoteImportJobDTO = try await api.request(
            path: "/v1/imports/\(jobID.uuidString)/retry",
            method: .post,
            body: RetryRequest(
                correctionNotes: correctionNotes,
                pastedText: pastedRecipeText
            ),
            appAttestPurpose: .importRetry
        )
        return try await update(from: response)
    }

    private func update(
        from response: RemoteImportJobDTO
    ) async throws -> ImportServiceUpdate {
        let remoteJobID = response.jobID.uuidString.lowercased()
        let progress: ImportServiceProgress
        var serverRevision: Int?

        switch try response.importStatus() {
        case .parsing:
            progress = .parsing
        case .ready:
            let remote = try await recipe(for: response)
            progress = .ready(try remote.recipe())
            serverRevision = remote.revision
        case .needsReview:
            let remote = try await recipe(for: response)
            progress = .needsReview(try remote.recipe())
            serverRevision = remote.revision
        case let .failed(reason):
            progress = .failed(reason)
        }
        return ImportServiceUpdate(
            remoteJobID: remoteJobID,
            progress: progress,
            serverRevision: serverRevision
        )
    }

    private func recipe(
        for response: RemoteImportJobDTO
    ) async throws -> RemoteRecipeDTO {
        guard let recipeID = response.recipeID else {
            throw APIError.decoding
        }
        return try await api.request(
            path: "/v1/recipes/\(recipeID.uuidString)"
        )
    }

    private func validatedJobID(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw APIError.invalidResponse
        }
        return id
    }
}
