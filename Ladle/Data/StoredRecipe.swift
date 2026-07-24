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
    var serverRevision: Int = 0
    var pendingMutationKey: String?
    var isDeleted: Bool = false
    var conflictRemotePayload: Data?
    var conflictRemoteRevision: Int?

    init(
        id: UUID,
        title: String,
        creatorName: String?,
        totalMinutes: Int?,
        calories: Double?,
        isFavorite: Bool,
        createdAt: Date,
        updatedAt: Date,
        payload: Data,
        serverRevision: Int = 0,
        pendingMutationKey: String? = nil,
        isDeleted: Bool = false,
        conflictRemotePayload: Data? = nil,
        conflictRemoteRevision: Int? = nil
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
        self.serverRevision = serverRevision
        self.pendingMutationKey = pendingMutationKey
        self.isDeleted = isDeleted
        self.conflictRemotePayload = conflictRemotePayload
        self.conflictRemoteRevision = conflictRemoteRevision
    }
}
