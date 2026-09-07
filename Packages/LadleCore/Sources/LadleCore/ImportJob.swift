import Foundation

/// Why an import ended in `failed`.
///
/// The server can learn a code before this build does, and the code arrives
/// inside the import poll's response — so a strict decode would throw on the
/// whole payload and leave every job in the response stuck parsing, not just
/// the one that failed. An unknown code therefore decodes as `unrecognized`,
/// which the app presents as a generic failure. The string rides along rather
/// than being discarded: the job is persisted as encoded JSON, so dropping it
/// would lose the real reason for good, and a later build that knows the code
/// reads the stored row correctly.
public enum ImportFailure: Codable, Error, Hashable, Sendable {
    case parserUnavailable
    case insufficientTextEvidence
    /// A photo post whose caption held no recipe. Distinct from the general
    /// case because the post is not the problem: the recipe is in pictures
    /// nothing here reads, so the way out is the cook, not another attempt.
    case photoPostNeedsManualEntry
    case privateOrDeleted
    case unsupportedSource
    case invalidURL
    case networkUnavailable
    case authenticationExpired
    case quotaExceeded
    case unrecognized(String)

    public var rawValue: String {
        switch self {
        case .parserUnavailable: "parserUnavailable"
        case .insufficientTextEvidence: "insufficientTextEvidence"
        case .photoPostNeedsManualEntry: "photoPostNeedsManualEntry"
        case .privateOrDeleted: "privateOrDeleted"
        case .unsupportedSource: "unsupportedSource"
        case .invalidURL: "invalidURL"
        case .networkUnavailable: "networkUnavailable"
        case .authenticationExpired: "authenticationExpired"
        case .quotaExceeded: "quotaExceeded"
        case let .unrecognized(code): code
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "parserUnavailable": self = .parserUnavailable
        case "insufficientTextEvidence": self = .insufficientTextEvidence
        case "photoPostNeedsManualEntry": self = .photoPostNeedsManualEntry
        case "privateOrDeleted": self = .privateOrDeleted
        case "unsupportedSource": self = .unsupportedSource
        case "invalidURL": self = .invalidURL
        case "networkUnavailable": self = .networkUnavailable
        case "authenticationExpired": self = .authenticationExpired
        case "quotaExceeded": self = .quotaExceeded
        default: self = .unrecognized(rawValue)
        }
    }

    /// Written by hand so the value stays the bare string every persisted job
    /// payload and every server response already carries.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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
    public private(set) var reviewCandidate: Recipe?

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
            copy.reviewCandidate = nil
        case .failed:
            copy.candidateRecipeID = nil
            copy.reviewCandidate = nil
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

    public func awaitingReview(
        candidate: Recipe,
        at date: Date = .now
    ) throws -> Self {
        var copy = try awaitingReview(recipeID: candidate.id, at: date)
        copy.reviewCandidate = candidate
        return copy
    }

    public func awaitingRemoteReview(
        candidate: Recipe,
        at date: Date = .now
    ) throws -> Self {
        var copy = try completingRemoteReimport(
            as: .needsReview,
            recipeID: candidate.id,
            at: date
        )
        copy.reviewCandidate = candidate
        return copy
    }

    public var reviewRecipeID: UUID? {
        guard case .needsReview = status else {
            return nil
        }
        return currentRecipeID ?? candidateRecipeID
    }

    public func keepingCurrentRecipe(
        at date: Date = .now
    ) throws -> Self {
        guard case .needsReview = status,
              currentRecipeID != nil,
              candidateRecipeID != nil else {
            throw ImportTransitionError.invalid(
                from: status,
                to: .ready
            )
        }
        var copy = self
        copy.status = .ready
        copy.updatedAt = date
        copy.candidateRecipeID = nil
        copy.reviewCandidate = nil
        return copy
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
        copy.reviewCandidate = nil
        return copy
    }

    public func completingRemoteReimport(
        as nextStatus: ImportStatus,
        recipeID: UUID,
        at date: Date = .now
    ) throws -> Self {
        guard currentRecipeID != nil,
              nextStatus == .ready || nextStatus == .needsReview else {
            throw ImportTransitionError.invalid(
                from: status,
                to: nextStatus
            )
        }
        var copy = try transitioning(to: nextStatus, at: date)
        switch nextStatus {
        case .ready:
            copy.currentRecipeID = recipeID
            copy.candidateRecipeID = nil
        case .needsReview:
            copy.candidateRecipeID = recipeID
        case .parsing, .failed:
            break
        }
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
