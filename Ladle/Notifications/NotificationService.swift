import LadleCore

enum ImportNotificationResult: Equatable {
    case scheduled
    case denied
    case failed
    case unavailable
}

@MainActor
protocol NotificationService: AnyObject {
    func notifyImportReady(
        recipe: Recipe
    ) async -> ImportNotificationResult
}

@MainActor
final class DisabledNotificationService: NotificationService {
    func notifyImportReady(
        recipe: Recipe
    ) async -> ImportNotificationResult {
        .unavailable
    }
}
