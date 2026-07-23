import Foundation

public struct FieldUncertainty: Codable, Hashable, Sendable {
    public let field: String
    public let reason: String
    public let confidence: Double?

    public init(
        field: String,
        reason: String,
        confidence: Double? = nil
    ) {
        self.field = field
        self.reason = reason
        self.confidence = confidence
    }
}
