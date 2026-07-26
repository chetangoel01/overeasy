import LadleCore
import UserNotifications

@MainActor
final class UserNotificationService: NotificationService {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func notifyImportReady(
        recipe: Recipe
    ) async -> ImportNotificationResult {
        do {
            let isAuthorized = try await center.requestAuthorization(
                options: [.alert, .sound]
            )
            guard isAuthorized else {
                return .denied
            }

            let content = UNMutableNotificationContent()
            content.title = "Recipe ready"
            content.body =
                "\(recipe.title) is ready to review and cook in Overeasy."
            content.sound = .default
            content.userInfo = [
                "recipeID": recipe.id.uuidString,
            ]

            let request = UNNotificationRequest(
                identifier:
                    "ladle.import-ready.\(recipe.id.uuidString)",
                content: content,
                trigger: nil
            )
            try await center.add(request)
            return .scheduled
        } catch {
            return .failed
        }
    }
}
