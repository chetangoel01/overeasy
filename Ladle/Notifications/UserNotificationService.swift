import LadleCore
import Observation
import UIKit
import UserNotifications

/// Where a tap has asked the app to go. Sendable because the notification
/// delegate builds one off the main actor and hands it over.
enum NotificationDestination: Hashable, Sendable {
    /// A finished import, which opens the recipe page.
    case recipe(UUID)
    /// A finished timer or an `overeasy://` link, which opens the cooking
    /// screen at the step that set the timer.
    case cookingStep(recipeID: UUID, stepID: UUID, timerID: UUID?)

    /// `overeasy://cooking/<recipeID>/steps/<stepID>`. The shape is a
    /// contract with the Live Activity (#178), so it is parsed in one place
    /// and nowhere else.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "overeasy",
              url.host()?.lowercased() == "cooking" else {
            return nil
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 3,
              components[1].lowercased() == "steps",
              let recipeID = UUID(uuidString: components[0]),
              let stepID = UUID(uuidString: components[2]) else {
            return nil
        }
        self = .cookingStep(
            recipeID: recipeID,
            stepID: stepID,
            timerID: nil
        )
    }

    /// The identifiers a timer alert carries back in its `userInfo`.
    init?(userInfo: [AnyHashable: Any]) {
        guard let value = userInfo["recipeID"] as? String,
              let recipeID = UUID(uuidString: value) else {
            return nil
        }
        guard let stepValue = userInfo["stepID"] as? String,
              let stepID = UUID(uuidString: stepValue) else {
            self = .recipe(recipeID)
            return
        }
        self = .cookingStep(
            recipeID: recipeID,
            stepID: stepID,
            timerID: (userInfo["timerID"] as? String)
                .flatMap(UUID.init(uuidString:))
        )
    }
}

@MainActor
@Observable
final class NotificationNavigation {
    static let shared = NotificationNavigation()

    private(set) var destination: NotificationDestination?

    /// The pending import-ready tap, and nothing else: a cooking
    /// destination is claimed by the runtime, not by the library.
    var recipeID: UUID? {
        guard case let .recipe(recipeID) = destination else {
            return nil
        }
        return recipeID
    }

    func open(_ destination: NotificationDestination) {
        self.destination = destination
    }

    func open(recipeID: UUID) {
        open(.recipe(recipeID))
    }

    func clear() {
        destination = nil
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

    /// A timer alert delivered while the app is in front drops its sound:
    /// `TimerAlarm` is already sounding the same chime, through a playback
    /// session that the ringer switch cannot silence, and the two together
    /// double the same event.
    nonisolated static func presentationOptions(
        for userInfo: [AnyHashable: Any]
    ) -> UNNotificationPresentationOptions {
        userInfo["timerID"] == nil
            ? foregroundPresentationOptions
            : [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.presentationOptions(
            for: notification.request.content.userInfo
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let destination = NotificationDestination(
            userInfo: response.notification.request.content.userInfo
        ) else {
            return
        }
        await NotificationNavigation.shared.open(destination)
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
