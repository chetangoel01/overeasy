import Foundation

public enum RemoteContractError: Error, Equatable, Sendable {
    case invalidDecimal(field: String, value: String)
    case invalidImportStatus
    /// The server reported a job the user had already cancelled. Distinct
    /// from `invalidImportStatus` so callers can drop the job instead of
    /// showing an import failure.
    case importCancelled
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

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    public static func encode<Value: Encodable>(
        _ value: Value
    ) throws -> Data {
        let encoded = try encoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded)
        return try JSONSerialization.data(
            withJSONObject: canonicalizeUUIDs(in: object)
        )
    }

    /// The wire keys that carry identifiers. The backend rejects UUIDs
    /// that are not lowercase, but `JSONEncoder` writes `UUID` as its
    /// uppercase `uuidString`, and by the time the encoded JSON is
    /// re-parsed a `UUID` field is indistinguishable from user-authored
    /// text that merely looks like one. Only the keys named here are
    /// rewritten, so a title or note that happens to be a UUID string
    /// survives byte-for-byte. A new UUID-typed request field must be
    /// added here — missing it fails loudly (the backend rejects the
    /// uppercase form) instead of silently rewriting prose.
    private static let identifierKeys: Set<String> = [
        "id",
        "ingredientIDs",
        "jobID",
        "recipeID",
        "currentRecipeID",
        "deviceID",
        "challengeID",
        "installationID",
        "idempotencyKey",
    ]

    private static func canonicalizeUUIDs(
        in value: Any,
        key: String? = nil
    ) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) {
                result, entry in
                result[entry.key] = canonicalizeUUIDs(
                    in: entry.value,
                    key: entry.key
                )
            }
        }
        if let array = value as? [Any] {
            // Elements of an identifier array ("ingredientIDs") inherit
            // the array's own key.
            return array.map { canonicalizeUUIDs(in: $0, key: key) }
        }
        if let key, identifierKeys.contains(key),
           let string = value as? String,
           let uuid = UUID(uuidString: string),
           string.caseInsensitiveCompare(uuid.uuidString) == .orderedSame {
            return uuid.uuidString.lowercased()
        }
        return value
    }
}

public enum RemoteImportStatus: String, Codable, Hashable, Sendable {
    case parsing
    case ready
    case needsReview
    case failed
    /// An idempotent re-submission can match a job the user already
    /// cancelled, so this has to decode rather than fail.
    case cancelled
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
        case (.cancelled, nil, nil):
            throw RemoteContractError.importCancelled
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

public struct DiscoverRecipe: Hashable, Identifiable, Sendable {
    public var id: UUID { sourceID }
    public let sourceID: UUID
    public let title: String
    public let description: String
    public let creatorName: String?
    public let source: RecipeSource
    public let originalURL: URL
    public let imageURL: URL?
    public let savedCount: Int
    /// The source platform's like count when it was last read. Nil for
    /// videos imported before counts were captured, and for providers that
    /// withhold them.
    public let likeCount: Int?
    public let savedRecipeID: UUID?

    public init(
        sourceID: UUID,
        title: String,
        description: String,
        creatorName: String?,
        source: RecipeSource,
        originalURL: URL,
        imageURL: URL?,
        savedCount: Int,
        likeCount: Int? = nil,
        savedRecipeID: UUID? = nil
    ) {
        self.sourceID = sourceID
        self.title = title
        self.description = description
        self.creatorName = creatorName
        self.source = source
        self.originalURL = originalURL
        self.imageURL = imageURL
        self.savedCount = savedCount
        self.likeCount = likeCount
        self.savedRecipeID = savedRecipeID
    }
}

public struct RemoteDiscoverRecipeDTO: Codable, Hashable, Sendable {
    public let sourceID: UUID
    public let title: String
    public let description: String
    public let creatorName: String?
    public let source: RemoteRecipeSource
    public let originalURL: URL
    public let imageURL: URL?
    public let savedCount: Int
    public let likeCount: Int?
    public let savedRecipeID: UUID?

    public func recipe() -> DiscoverRecipe {
        DiscoverRecipe(
            sourceID: sourceID,
            title: title,
            description: description,
            creatorName: creatorName,
            source: source.recipeSource,
            originalURL: originalURL,
            imageURL: imageURL,
            savedCount: savedCount,
            likeCount: likeCount,
            savedRecipeID: savedRecipeID
        )
    }
}

public struct RemoteDiscoverPageDTO: Codable, Hashable, Sendable {
    public let items: [RemoteDiscoverRecipeDTO]
    /// Offset to pass back as `cursor` for the next page. Counts ranked rows
    /// consumed, not items returned, so a page may be shorter than the limit
    /// without paging stalling.
    public let nextCursor: Int
    public let hasMore: Bool
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

    public init(_ value: FieldUncertainty) {
        field = value.field
        reason = value.reason
        confidence = value.confidence
    }

    fileprivate func uncertainty() -> FieldUncertainty {
        FieldUncertainty(field: field, reason: reason, confidence: confidence)
    }
}

public struct RemoteRecipeImageDTO: Codable, Hashable, Sendable {
    public let id: UUID
    public let remoteURL: URL

    public init(id: UUID, remoteURL: URL) {
        self.id = id
        self.remoteURL = remoteURL
    }

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

    public init(_ value: Ingredient) {
        id = value.id
        quantityText = value.quantityText
        normalizedQuantity = value.normalizedQuantity.map(remoteDecimalString)
        unit = value.unit
        name = value.name
        preparation = value.preparation
        orderIndex = value.orderIndex
        uncertainty = value.uncertainty.map(RemoteFieldUncertaintyDTO.init)
    }

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

    public init(_ value: DetectedTimer) {
        id = value.id
        label = value.label
        durationSeconds = value.durationSeconds
    }

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
    public let sourceStartSeconds: Double?
    public let sourceEndSeconds: Double?
    public let uncertainty: RemoteFieldUncertaintyDTO?

    public init(_ value: RecipeStep) {
        id = value.id
        orderIndex = value.orderIndex
        instruction = value.instruction
        ingredientIDs = value.ingredientIDs
        timers = value.timers.map(RemoteDetectedTimerDTO.init)
        sourceStartSeconds = value.sourceStartSeconds
        sourceEndSeconds = value.sourceEndSeconds
        uncertainty = value.uncertainty.map(RemoteFieldUncertaintyDTO.init)
    }

    fileprivate func step() -> RecipeStep {
        RecipeStep(
            id: id,
            orderIndex: orderIndex,
            instruction: instruction,
            ingredientIDs: ingredientIDs,
            timers: timers.map { $0.timer() },
            sourceStartSeconds: sourceStartSeconds,
            sourceEndSeconds: sourceEndSeconds,
            uncertainty: uncertainty?.uncertainty()
        )
    }
}

public struct RemoteNutrientDTO: Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let amount: String
    public let unit: String

    public init(_ value: Nutrient) {
        id = value.id
        name = value.name
        amount = remoteDecimalString(value.amount)
        unit = value.unit
    }

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

    public init(_ value: Nutrition) {
        calories = value.calories.map(remoteDecimalString)
        proteinGrams = value.proteinGrams.map(remoteDecimalString)
        carbohydrateGrams = value.carbohydrateGrams.map(remoteDecimalString)
        fatGrams = value.fatGrams.map(remoteDecimalString)
        saturatedFatGrams = value.saturatedFatGrams.map(remoteDecimalString)
        fiberGrams = value.fiberGrams.map(remoteDecimalString)
        sugarGrams = value.sugarGrams.map(remoteDecimalString)
        sodiumMilligrams = value.sodiumMilligrams.map(remoteDecimalString)
        otherNutrients = value.otherNutrients.map(RemoteNutrientDTO.init)
        servingBasis = remoteDecimalString(value.servingBasis)
        isEstimated = value.isEstimated
    }

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
    public let notes: [String]
    public let isFavorite: Bool
    public let reviewStatus: RecipeReviewStatus
    public let uncertainties: [RemoteFieldUncertaintyDTO]
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(recipe: Recipe, revision: Int) {
        id = recipe.id
        title = recipe.title
        description = recipe.description
        creatorName = recipe.creatorName
        source = switch recipe.source {
        case .tiktok: .tiktok
        case .instagram: .instagram
        case .youtube: .youtube
        case .other: .other
        }
        originalURL = recipe.originalURL
        images = recipe.images.compactMap { image in
            image.remoteURL.map {
                RemoteRecipeImageDTO(id: image.id, remoteURL: $0)
            }
        }
        preparationMinutes = recipe.preparationMinutes
        cookingMinutes = recipe.cookingMinutes
        totalMinutes = recipe.totalMinutes
        servings = remoteDecimalString(recipe.servings)
        ingredients = recipe.ingredients.map(RemoteIngredientDTO.init)
        steps = recipe.steps.map(RemoteRecipeStepDTO.init)
        nutrition = recipe.nutrition.map(RemoteNutritionDTO.init)
        notes = recipe.notes
        isFavorite = recipe.isFavorite
        reviewStatus = recipe.reviewStatus
        uncertainties = recipe.uncertainties.map(
            RemoteFieldUncertaintyDTO.init
        )
        self.revision = revision
        createdAt = recipe.createdAt
        updatedAt = recipe.updatedAt
    }

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
            notes: notes,
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
    case invalidRequest
    case invalidURL
    case unsupportedSource
    case duplicateRecipe
    case guestRecipeLimitReached
    case authenticationRequired
    case syncConflict
    case syncResetRequired
    case providerUnavailable
    case quotaExceeded
    case rateLimited
    case notFound
    case conflict
    case internalError
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

private func remoteDecimalString(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).stringValue
}
