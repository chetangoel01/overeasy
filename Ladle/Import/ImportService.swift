import LadleCore

enum ImportServiceOutcome: Equatable, Sendable {
    case ready(Recipe)
    case needsReview(Recipe)
    case failed(ImportFailure)
}

protocol ImportService: Sendable {
    func importRecipe(
        for job: ImportJob
    ) async throws -> ImportServiceOutcome
}
