import LadleCore
import Observation
import UIKit
import UserNotifications

@MainActor
@Observable
final class NotificationNavigation {
    static let shared = NotificationNavigation()

    private(set) var recipeID: UUID?

    func open(recipeID: UUID) {
        self.recipeID = recipeID
    }

    func clear() {
        recipeID = nil
    }
}

final class LadleAppDelegate: NSObject, UIApplicationDelegate,
    UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// How a notification delivered while the app is foregrounded is
    /// shown. iOS silences foreground deliveries entirely unless the
    /// delegate implements `willPresent` and returns options — without
    /// this, an import finishing while the user browses the app produced
    /// no banner, sound, or Notification Center entry while
    /// `notifyImportReady` still reported `.scheduled`.
    nonisolated static let foregroundPresentationOptions:
        UNNotificationPresentationOptions = [.banner, .list, .sound]

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentationOptions
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let value = response.notification.request.content.userInfo[
            "recipeID"
        ] as? String,
        let recipeID = UUID(uuidString: value) else {
            return
        }
        await NotificationNavigation.shared.open(recipeID: recipeID)
    }
}

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
