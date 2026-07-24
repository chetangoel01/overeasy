import Foundation

public enum RemoteContractError: Error, Equatable, Sendable {
    case invalidDecimal(field: String, value: String)
    case invalidImportStatus
}

public enum RemoteContractJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard value.hasSuffix("Z") else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a UTC ISO-8601 timestamp"
                )
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 timestamp"
                )
            }
            return date
        }
        return decoder
    }
}

public enum RemoteImportStatus: String, Codable, Hashable, Sendable {
    case parsing
    case ready
    case needsReview
    case failed
}

public struct RemoteImportJobDTO: Codable, Hashable, Sendable {
    public let jobID: UUID
    public let status: RemoteImportStatus
    public let failureReason: ImportFailure?
    public let recipeID: UUID?
    public let retryCount: Int
    public let createdAt: Date
    public let updatedAt: Date

    public func importStatus() throws -> ImportStatus {
        switch (status, failureReason, recipeID) {
        case (.parsing, nil, nil):
            .parsing
        case (.ready, nil, .some):
            .ready
        case (.needsReview, nil, .some):
            .needsReview
        case let (.failed, .some(failure), nil):
            .failed(failure)
        default:
            throw RemoteContractError.invalidImportStatus
        }
    }
}

public enum RemoteRecipeSource: Hashable, Sendable {
    case tiktok
    case instagram
    case youtube
    case other

    public var recipeSource: RecipeSource {
        switch self {
        case .tiktok: .tiktok
        case .instagram: .instagram
        case .youtube: .youtube
        case .other: .other
        }
    }
}

extension RemoteRecipeSource: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "tiktok": self = .tiktok
        case "instagram": self = .instagram
        case "youtube": self = .youtube
        default: self = .other
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let value = switch self {
        case .tiktok: "tiktok"
        case .instagram: "instagram"
        case .youtube: "youtube"
        case .other: "other"
        }
        try container.encode(value)
    }
}

public struct RemoteFieldUncertaintyDTO: Codable, Hashable, Sendable {
    public let field: String
    public let reason: String
    public let confidence: Double?

    fileprivate func uncertainty() -> FieldUncertainty {
        FieldUncertainty(field: field, reason: reason, confidence: confidence)
    }
}

public struct RemoteRecipeImageDTO: Codable, Hashable, Sendable {
    public let id: UUID
    public let remoteURL: URL

    fileprivate func image() -> RecipeImage {
        RecipeImage(id: id, remoteURL: remoteURL)
    }
}

public struct RemoteIngredientDTO: Codable, Hashable, Sendable {
    public let id: UUID
    public let quantityText: String?
    public let normalizedQuantity: String?
    public let unit: String?
    public let name: String
    public let preparation: String?
    public let orderIndex: Int
    public let uncertainty: RemoteFieldUncertaintyDTO?

    fileprivate func ingredient() throws -> Ingredient {
        Ingredient(
            id: id,
            quantityText: quantityText,
            normalizedQuantity: try normalizedQuantity.map {
                try remoteDecimal($0, field: "normalizedQuantity")
            },
            unit: unit,
            name: name,
            preparation: preparation,
            orderIndex: orderIndex,
            uncertainty: uncertainty?.uncertainty()
        )
    }
}

public struct RemoteDetectedTimerDTO: Codable, Hashable, Sendable {
    public let id: UUID
    public let label: String
    public let durationSeconds: Int

    fileprivate func timer() -> DetectedTimer {
        DetectedTimer(id: id, label: label, durationSeconds: durationSeconds)
    }
}

public struct RemoteRecipeStepDTO: Codable, Hashable, Sendable {
    public let id: UUID
    public let orderIndex: Int
    public let instruction: String
    public let ingredientIDs: [UUID]
    public let timers: [RemoteDetectedTimerDTO]
    public let uncertainty: RemoteFieldUncertaintyDTO?

    fileprivate func step() -> RecipeStep {
        RecipeStep(
            id: id,
            orderIndex: orderIndex,
            instruction: instruction,
            ingredientIDs: ingredientIDs,
            timers: timers.map { $0.timer() },
            uncertainty: uncertainty?.uncertainty()
        )
    }
}

public struct RemoteNutrientDTO: Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let amount: String
    public let unit: String

    fileprivate func nutrient() throws -> Nutrient {
        Nutrient(
            id: id,
            name: name,
            amount: try remoteDecimal(amount, field: "otherNutrients.amount"),
            unit: unit
        )
    }
}

public struct RemoteNutritionDTO: Codable, Hashable, Sendable {
    public let calories: String?
    public let proteinGrams: String?
    public let carbohydrateGrams: String?
    public let fatGrams: String?
    public let saturatedFatGrams: String?
    public let fiberGrams: String?
    public let sugarGrams: String?
    public let sodiumMilligrams: String?
    public let otherNutrients: [RemoteNutrientDTO]
    public let servingBasis: String
    public let isEstimated: Bool

    fileprivate func nutrition() throws -> Nutrition {
        Nutrition(
            calories: try decimal(calories, field: "calories"),
            proteinGrams: try decimal(proteinGrams, field: "proteinGrams"),
            carbohydrateGrams: try decimal(
                carbohydrateGrams,
                field: "carbohydrateGrams"
            ),
            fatGrams: try decimal(fatGrams, field: "fatGrams"),
            saturatedFatGrams: try decimal(
                saturatedFatGrams,
                field: "saturatedFatGrams"
            ),
            fiberGrams: try decimal(fiberGrams, field: "fiberGrams"),
            sugarGrams: try decimal(sugarGrams, field: "sugarGrams"),
            sodiumMilligrams: try decimal(
                sodiumMilligrams,
                field: "sodiumMilligrams"
            ),
            otherNutrients: try otherNutrients.map { try $0.nutrient() },
            servingBasis: try remoteDecimal(servingBasis, field: "servingBasis"),
            isEstimated: isEstimated
        )
    }

    private func decimal(_ value: String?, field: String) throws -> Decimal? {
        try value.map { try remoteDecimal($0, field: field) }
    }
}

public struct RemoteRecipeDTO: Codable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let description: String
    public let creatorName: String?
    public let source: RemoteRecipeSource
    public let originalURL: URL
    public let images: [RemoteRecipeImageDTO]
    public let preparationMinutes: Int?
    public let cookingMinutes: Int?
    public let totalMinutes: Int?
    public let servings: String
    public let ingredients: [RemoteIngredientDTO]
    public let steps: [RemoteRecipeStepDTO]
    public let nutrition: RemoteNutritionDTO?
    public let isFavorite: Bool
    public let reviewStatus: RecipeReviewStatus
    public let uncertainties: [RemoteFieldUncertaintyDTO]
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date

    public func recipe() throws -> Recipe {
        Recipe(
            id: id,
            title: title,
            description: description,
            creatorName: creatorName,
            source: source.recipeSource,
            originalURL: originalURL,
            images: images.map { $0.image() },
            preparationMinutes: preparationMinutes,
            cookingMinutes: cookingMinutes,
            totalMinutes: totalMinutes,
            servings: try remoteDecimal(servings, field: "servings"),
            ingredients: try ingredients.map { try $0.ingredient() },
            steps: steps.map { $0.step() },
            nutrition: try nutrition?.nutrition(),
            isFavorite: isFavorite,
            reviewStatus: reviewStatus,
            uncertainties: uncertainties.map { $0.uncertainty() },
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

public enum RemoteSyncChangeKind: String, Codable, Hashable, Sendable {
    case upsert
    case delete
}

public struct RemoteRecipeChangeDTO: Codable, Hashable, Sendable {
    public let sequence: Int64
    public let recipeID: UUID
    public let kind: RemoteSyncChangeKind
    public let recipeRevision: Int
    public let changedAt: Date
    public let recipe: RemoteRecipeDTO?
}

public struct RemoteSyncPageDTO: Codable, Hashable, Sendable {
    public let changes: [RemoteRecipeChangeDTO]
    public let nextCursor: Int64
    public let hasMore: Bool
}

public enum RemoteErrorCode: String, Codable, Hashable, Sendable {
    case invalidURL
    case unsupportedSource
    case duplicateRecipe
    case guestRecipeLimitReached
    case authenticationRequired
    case syncConflict
    case providerUnavailable
    case quotaExceeded
    case rateLimited
}

public enum RemoteErrorDetails: Hashable, Sendable {
    case duplicate(existingRecipeID: UUID)
    case syncConflict(currentRecipe: RemoteRecipeDTO, currentRevision: Int)
    case rateLimit(retryAt: Date)
}

public struct RemoteErrorDTO: Decodable, Hashable, Sendable {
    public let code: RemoteErrorCode
    public let message: String
    public let retryable: Bool
    public let requestID: UUID
    public let details: RemoteErrorDetails?

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case retryable
        case requestID
        case details
    }

    private struct DuplicateDetails: Decodable {
        let existingRecipeID: UUID
    }

    private struct SyncConflictDetails: Decodable {
        let currentRecipe: RemoteRecipeDTO
        let currentRevision: Int
    }

    private struct RateLimitDetails: Decodable {
        let retryAt: Date
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(RemoteErrorCode.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        retryable = try container.decode(Bool.self, forKey: .retryable)
        requestID = try container.decode(UUID.self, forKey: .requestID)

        switch code {
        case .duplicateRecipe:
            let value = try container.decode(
                DuplicateDetails.self,
                forKey: .details
            )
            details = .duplicate(existingRecipeID: value.existingRecipeID)
        case .syncConflict:
            let value = try container.decode(
                SyncConflictDetails.self,
                forKey: .details
            )
            details = .syncConflict(
                currentRecipe: value.currentRecipe,
                currentRevision: value.currentRevision
            )
        case .rateLimited:
            let value = try container.decode(
                RateLimitDetails.self,
                forKey: .details
            )
            details = .rateLimit(retryAt: value.retryAt)
        default:
            if container.contains(.details),
               try !container.decodeNil(forKey: .details)
            {
                throw DecodingError.dataCorruptedError(
                    forKey: .details,
                    in: container,
                    debugDescription: "\(code.rawValue) does not accept details"
                )
            }
            details = nil
        }
    }
}

public struct RemoteErrorEnvelope: Decodable, Hashable, Sendable {
    public let error: RemoteErrorDTO
}

private func remoteDecimal(_ value: String, field: String) throws -> Decimal {
    guard let decimal = Decimal(
        string: value,
        locale: Locale(identifier: "en_US_POSIX")
    ) else {
        throw RemoteContractError.invalidDecimal(field: field, value: value)
    }
    return decimal
}
