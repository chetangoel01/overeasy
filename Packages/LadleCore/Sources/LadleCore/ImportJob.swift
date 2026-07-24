import Foundation

public enum ImportFailure: String, Codable, Error, Hashable, Sendable {
    case parserUnavailable
    case privateOrDeleted
    case unsupportedSource
    case invalidURL
    case networkUnavailable
}

public enum ImportStatus: Codable, Hashable, Sendable {
    case parsing
    case ready
    case needsReview
    case failed(ImportFailure)
}

public enum ImportTransitionError: Error, Equatable {
    case invalid(from: ImportStatus, to: ImportStatus)
}

public struct ImportJob: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let source: RecipeSource
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var status: ImportStatus
    public private(set) var retryCount: Int
    public var correctionNotes: String?
    public var pastedRecipeText: String?
    public var remoteJobID: String?
    public private(set) var currentRecipeID: UUID?
    public private(set) var candidateRecipeID: UUID?

    public static func queued(
        sourceURL: URL,
        source: RecipeSource = .other,
        id: UUID = UUID(),
        createdAt: Date = .now
    ) -> Self {
        Self(
            id: id,
            sourceURL: sourceURL,
            source: source,
            createdAt: createdAt,
            updatedAt: createdAt,
            status: .parsing,
            retryCount: 0
        )
    }

    public static func reimporting(
        sourceURL: URL,
        source: RecipeSource = .other,
        currentRecipeID: UUID,
        candidateRecipeID: UUID,
        id: UUID = UUID(),
        createdAt: Date = .now
    ) -> Self {
        Self(
            id: id,
            sourceURL: sourceURL,
            source: source,
            createdAt: createdAt,
            updatedAt: createdAt,
            status: .parsing,
            retryCount: 0,
            currentRecipeID: currentRecipeID,
            candidateRecipeID: candidateRecipeID
        )
    }

    public func transitioning(
        to nextStatus: ImportStatus,
        at date: Date = .now
    ) throws -> Self {
        guard Self.allowsTransition(from: status, to: nextStatus) else {
            throw ImportTransitionError.invalid(from: status, to: nextStatus)
        }

        var copy = self
        copy.status = nextStatus
        copy.updatedAt = date

        switch nextStatus {
        case .ready:
            if let candidateRecipeID {
                copy.currentRecipeID = candidateRecipeID
                copy.candidateRecipeID = nil
            }
        case .failed:
            copy.candidateRecipeID = nil
        case .parsing:
            copy.retryCount += 1
        case .needsReview:
            break
        }

        return copy
    }

    public func awaitingReview(
        recipeID: UUID,
        at date: Date = .now
    ) throws -> Self {
        if let candidateRecipeID, candidateRecipeID != recipeID {
            throw ImportTransitionError.invalid(
                from: status,
                to: .needsReview
            )
        }
        var copy = try transitioning(to: .needsReview, at: date)
        if copy.candidateRecipeID == nil {
            copy.currentRecipeID = recipeID
        }
        return copy
    }

    public var reviewRecipeID: UUID? {
        guard case .needsReview = status else {
            return nil
        }
        return candidateRecipeID ?? currentRecipeID
    }

    public func retryingReimport(
        candidateRecipeID: UUID,
        at date: Date = .now
    ) throws -> Self {
        guard currentRecipeID != nil else {
            throw ImportTransitionError.invalid(
                from: status,
                to: .parsing
            )
        }
        var copy = try transitioning(to: .parsing, at: date)
        copy.candidateRecipeID = candidateRecipeID
        return copy
    }

    private static func allowsTransition(
        from current: ImportStatus,
        to next: ImportStatus
    ) -> Bool {
        switch (current, next) {
        case (.parsing, .ready),
             (.parsing, .needsReview),
             (.parsing, .failed),
             (.needsReview, .ready),
             (.needsReview, .failed),
             (.failed, .parsing):
            true
        default:
            false
        }
    }
}
