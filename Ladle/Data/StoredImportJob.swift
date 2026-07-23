import Foundation
import SwiftData

@Model
final class StoredImportJob {
    @Attribute(.unique) var id: UUID
    var sourceURLString: String
    var statusKey: String
    var createdAt: Date
    var updatedAt: Date
    var currentRecipeID: UUID?
    var payload: Data

    init(
        id: UUID,
        sourceURLString: String,
        statusKey: String,
        createdAt: Date,
        updatedAt: Date,
        currentRecipeID: UUID?,
        payload: Data
    ) {
        self.id = id
        self.sourceURLString = sourceURLString
        self.statusKey = statusKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.currentRecipeID = currentRecipeID
        self.payload = payload
    }
}
