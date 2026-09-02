import Foundation

public enum RecipeReviewStatus: String, Codable, Hashable, Sendable {
    case ready
    case needsReview
}

public enum RecipeCookingReadiness: Equatable, Sendable {
    case ready
    case needsReview
    case missingIngredients
    case missingMethod
}

public struct RecipeImage: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let localName: String?
    public let remoteURL: URL?

    public init(
        id: UUID = UUID(),
        localName: String? = nil,
        remoteURL: URL? = nil
    ) {
        self.id = id
        self.localName = localName
        self.remoteURL = remoteURL
    }
}

public struct Ingredient: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var quantityText: String?
    public var normalizedQuantity: Decimal?
    public var unit: String?
    public var name: String
    public var preparation: String?
    public var orderIndex: Int
    public var uncertainty: FieldUncertainty?

    public init(
        id: UUID = UUID(),
        quantityText: String? = nil,
        normalizedQuantity: Decimal? = nil,
        unit: String? = nil,
        name: String,
        preparation: String? = nil,
        orderIndex: Int,
        uncertainty: FieldUncertainty? = nil
    ) {
        self.id = id
        self.quantityText = quantityText
        self.normalizedQuantity = normalizedQuantity
        self.unit = unit
        self.name = name
        self.preparation = preparation
        self.orderIndex = orderIndex
        self.uncertainty = uncertainty
    }
}

public struct DetectedTimer: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let label: String
    public let durationSeconds: Int

    public init(
        id: UUID = UUID(),
        label: String,
        durationSeconds: Int
    ) {
        self.id = id
        self.label = label
        self.durationSeconds = durationSeconds
    }
}

public struct RecipeStep: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var orderIndex: Int
    public var instruction: String
    public var ingredientIDs: [UUID]
    public var timers: [DetectedTimer]
    /// Transcript window this step came from, when the source carried
    /// timestamps. Enables jumping the video to the matching moment.
    public var sourceStartSeconds: Double?
    public var sourceEndSeconds: Double?
    public var uncertainty: FieldUncertainty?

    public init(
        id: UUID = UUID(),
        orderIndex: Int,
        instruction: String,
        ingredientIDs: [UUID] = [],
        timers: [DetectedTimer] = [],
        sourceStartSeconds: Double? = nil,
        sourceEndSeconds: Double? = nil,
        uncertainty: FieldUncertainty? = nil
    ) {
        self.id = id
        self.orderIndex = orderIndex
        self.instruction = instruction
        self.ingredientIDs = ingredientIDs
        self.timers = timers
        self.sourceStartSeconds = sourceStartSeconds
        self.sourceEndSeconds = sourceEndSeconds
        self.uncertainty = uncertainty
    }
}

public struct Recipe: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var description: String
    public var creatorName: String?
    public var source: RecipeSource
    public var originalURL: URL
    public var images: [RecipeImage]
    public var preparationMinutes: Int?
    public var cookingMinutes: Int?
    public var totalMinutes: Int?
    public var servings: Decimal
    public var ingredients: [Ingredient]
    public var steps: [RecipeStep]
    public var nutrition: Nutrition?
    /// Creator caveats and context that belong beside the recipe rather
    /// than inside its ingredient or step lists.
    public var notes: [String]
    public var isFavorite: Bool
    public var reviewStatus: RecipeReviewStatus
    public var uncertainties: [FieldUncertainty]
    public var lastCookedAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        description: String = "",
        creatorName: String? = nil,
        source: RecipeSource,
        originalURL: URL,
        images: [RecipeImage] = [],
        preparationMinutes: Int? = nil,
        cookingMinutes: Int? = nil,
        totalMinutes: Int? = nil,
        servings: Decimal,
        ingredients: [Ingredient] = [],
        steps: [RecipeStep] = [],
        nutrition: Nutrition? = nil,
        notes: [String] = [],
        isFavorite: Bool = false,
        reviewStatus: RecipeReviewStatus = .ready,
        uncertainties: [FieldUncertainty] = [],
        lastCookedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.creatorName = creatorName
        self.source = source
        self.originalURL = originalURL
        self.images = images
        self.preparationMinutes = preparationMinutes
        self.cookingMinutes = cookingMinutes
        self.totalMinutes = totalMinutes
        self.servings = servings
        self.ingredients = ingredients
        self.steps = steps
        self.nutrition = nutrition
        self.notes = notes
        self.isFavorite = isFavorite
        self.reviewStatus = reviewStatus
        self.uncertainties = uncertainties
        self.lastCookedAt = lastCookedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Decoded leniently so payloads persisted before a field existed still
    /// load. Synthesized decoding would throw `keyNotFound` for any
    /// non-optional addition and take the whole local library with it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(
            String.self,
            forKey: .description
        ) ?? ""
        creatorName = try container.decodeIfPresent(
            String.self,
            forKey: .creatorName
        )
        source = try container.decode(RecipeSource.self, forKey: .source)
        originalURL = try container.decode(URL.self, forKey: .originalURL)
        images = try container.decodeIfPresent(
            [RecipeImage].self,
            forKey: .images
        ) ?? []
        preparationMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .preparationMinutes
        )
        cookingMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .cookingMinutes
        )
        totalMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .totalMinutes
        )
        servings = try container.decode(Decimal.self, forKey: .servings)
        ingredients = try container.decodeIfPresent(
            [Ingredient].self,
            forKey: .ingredients
        ) ?? []
        steps = try container.decodeIfPresent(
            [RecipeStep].self,
            forKey: .steps
        ) ?? []
        nutrition = try container.decodeIfPresent(
            Nutrition.self,
            forKey: .nutrition
        )
        notes = try container.decodeIfPresent(
            [String].self,
            forKey: .notes
        ) ?? []
        isFavorite = try container.decodeIfPresent(
            Bool.self,
            forKey: .isFavorite
        ) ?? false
        reviewStatus = try container.decodeIfPresent(
            RecipeReviewStatus.self,
            forKey: .reviewStatus
        ) ?? .ready
        uncertainties = try container.decodeIfPresent(
            [FieldUncertainty].self,
            forKey: .uncertainties
        ) ?? []
        lastCookedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastCookedAt
        )
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public var orderedIngredients: [Ingredient] {
        ingredients.sorted {
            ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString)
        }
    }

    public var orderedSteps: [RecipeStep] {
        steps.sorted {
            ($0.orderIndex, $0.id.uuidString) < ($1.orderIndex, $1.id.uuidString)
        }
    }

    /// The one time worth showing, with the label that is true of it.
    ///
    /// Creators state a cook time far more often than a total, so reading
    /// `totalMinutes` alone leaves a recipe that has an honest number
    /// showing nothing. Falling back keeps the band, the time filter, the
    /// time sort and the Discover shelf on the same rule.
    public var displayedTime: (minutes: Int, label: String)? {
        if let totalMinutes {
            return (totalMinutes, "Total time")
        }
        switch (preparationMinutes, cookingMinutes) {
        case let (preparation?, cooking?):
            return (preparation + cooking, "Total time")
        case (nil, let cooking?):
            return (cooking, "Cook time")
        case (let preparation?, nil):
            return (preparation, "Prep time")
        case (nil, nil):
            return nil
        }
    }

    /// True when the total was read off the method rather than stated by the
    /// creator, so a cook is told the number is approximate.
    public var isTimeEstimated: Bool {
        uncertainties.contains { $0.field == "total_minutes" }
    }

    public var cookingReadiness: RecipeCookingReadiness {
        if reviewStatus == .needsReview {
            return .needsReview
        }
        if ingredients.isEmpty {
            return .missingIngredients
        }
        if steps.isEmpty {
            return .missingMethod
        }
        return .ready
    }

    public var canStartCooking: Bool {
        cookingReadiness == .ready
    }
}
