import Foundation
import SwiftData

@Model
final class StoredRecipe {
    @Attribute(.unique) var id: UUID
    var title: String
    var creatorName: String?
    var totalMinutes: Int?
    var calories: Double?
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    var payload: Data

    init(
        id: UUID,
        title: String,
        creatorName: String?,
        totalMinutes: Int?,
        calories: Double?,
        isFavorite: Bool,
        createdAt: Date,
        updatedAt: Date,
        payload: Data
    ) {
        self.id = id
        self.title = title
        self.creatorName = creatorName
        self.totalMinutes = totalMinutes
        self.calories = calories
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.payload = payload
    }
}
