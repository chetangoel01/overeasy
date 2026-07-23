import Foundation

public struct SharedImportEnvelope:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    public let id: UUID
    public let sourceURL: URL
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.createdAt = createdAt
    }
}
