import Foundation
import LadleCore
import UserNotifications
import XCTest
@testable import Ladle

@MainActor
final class NotificationServiceTests: XCTestCase {
    func testNotificationNavigationTargetsOneRecipeThenClears() {
        let navigation = NotificationNavigation()
        let recipeID = UUID()

        navigation.open(recipeID: recipeID)
        XCTAssertEqual(navigation.recipeID, recipeID)

        navigation.clear()
        XCTAssertNil(navigation.recipeID)
    }

    func testReadyImportRequestsOneCompletionNotificationInContext() async {
        let recipe = notificationRecipe()
        let repository = NotificationTestRepository()
        let notifications = TestNotificationService()
        let coordinator = makeCoordinator(
            repository: repository,
            outcome: .ready(recipe),
            notifications: notifications
        )

        XCTAssertTrue(notifications.notifiedRecipeIDs.isEmpty)

        await coordinator.submit(
            urlText: recipe.originalURL.absoluteString
        )

        XCTAssertEqual(notifications.notifiedRecipeIDs, [recipe.id])
        XCTAssertEqual(repository.importJobs.first?.status, .ready)
        XCTAssertEqual(
            coordinator.state,
            .completed(recipeID: recipe.id)
        )
    }

    func testNeedsReviewAndFailedImportsDoNotScheduleNotifications() async {
        let recipe = notificationRecipe()
        let repository = NotificationTestRepository()
        let notifications = TestNotificationService()

        let reviewCoordinator = makeCoordinator(
            repository: repository,
            outcome: .needsReview(recipe),
            notifications: notifications
        )
        await reviewCoordinator.submit(
            urlText: recipe.originalURL.absoluteString
        )

        let failedCoordinator = makeCoordinator(
            repository: repository,
            outcome: .failed(.parserUnavailable),
            notifications: notifications
        )
        await failedCoordinator.submit(
            urlText:
                "https://www.tiktok.com/@ladle/video/notification-failed"
        )

        XCTAssertTrue(notifications.notifiedRecipeIDs.isEmpty)
    }

    func testNotificationDenialCannotRollBackReadyRepositoryState() async {
        let recipe = notificationRecipe()
        let repository = NotificationTestRepository()
        let notifications = TestNotificationService(result: .denied)
        let coordinator = makeCoordinator(
            repository: repository,
            outcome: .ready(recipe),
            notifications: notifications
        )

        await coordinator.submit(
            urlText: recipe.originalURL.absoluteString
        )

        XCTAssertEqual(repository.recipes, [recipe])
        XCTAssertEqual(repository.importJobs.first?.status, .ready)
        XCTAssertEqual(
            coordinator.state,
            .completed(recipeID: recipe.id)
        )
        XCTAssertEqual(notifications.notifiedRecipeIDs, [recipe.id])
    }

    func testForegroundDeliveryIsPresentedNotSilenced() {
        // Import completion effectively always happens with the app
        // active (there are no background modes), and iOS silences a
        // delivery while foregrounded unless the delegate implements
        // willPresent and returns presentation options.
        XCTAssertTrue(
            LadleAppDelegate().responds(
                to: #selector(
                    UNUserNotificationCenterDelegate
                        .userNotificationCenter(
                            _:
                            willPresent:
                            withCompletionHandler:
                        )
                )
            ),
            "Without willPresent, a notification posted while the app is"
                + " foregrounded shows no banner while notifyImportReady"
                + " still reports .scheduled"
        )
        XCTAssertEqual(
            LadleAppDelegate.foregroundPresentationOptions,
            [.banner, .list, .sound]
        )
    }

    func testBannerTapForABackgroundImportReloadsTheStaleLibraryAndOpensIt() {
        // Several links shared together resume as one owned operation
        // plus unowned background jobs. An unowned job saves its recipe
        // durably and posts the "Recipe ready" banner without touching
        // the published import state, so nothing reloads the in-memory
        // library before the tap lands.
        let alreadyVisible = notificationRecipe()
        let repository = NotificationTestRepository()
        repository.recipes = [alreadyVisible]
        let navigation = NotificationNavigation()
        let library = makeLibrary(repository: repository)
        library.load()

        let imported = backgroundImportedRecipe()
        repository.recipes.append(imported)
        navigation.open(recipeID: imported.id)

        XCTAssertEqual(
            navigation.claimRecipe(in: library)?.id,
            imported.id,
            "A tapped banner must open the recipe even when the loaded"
                + " library predates the background import"
        )
        XCTAssertNil(
            navigation.recipeID,
            "A handled tap must consume the pending navigation"
        )
    }

    func testBannerTapForAMissingRecipeIsConsumedSoTheNextTapStillFires() {
        let repository = NotificationTestRepository()
        repository.recipes = [notificationRecipe()]
        let navigation = NotificationNavigation()
        let library = makeLibrary(repository: repository)
        library.load()

        let lateRecipe = backgroundImportedRecipe()
        navigation.open(recipeID: lateRecipe.id)

        XCTAssertNil(navigation.claimRecipe(in: library))
        XCTAssertNil(
            navigation.recipeID,
            "A failed match must not leave the navigation pinned to the"
                + " same recipe ID — .task(id:) would never re-fire and"
                + " every later tap for that recipe would land dead"
        )

        // The import lands afterwards and the user taps the banner
        // again from Notification Center: the same recipe ID must be
        // accepted afresh and the claim must now succeed.
        repository.recipes.append(lateRecipe)
        navigation.open(recipeID: lateRecipe.id)

        XCTAssertEqual(navigation.recipeID, lateRecipe.id)
        XCTAssertEqual(
            navigation.claimRecipe(in: library)?.id,
            lateRecipe.id
        )
    }

    func testBannerTapForALoadedRecipeOpensWithoutReloading() {
        let recipe = notificationRecipe()
        let repository = NotificationTestRepository()
        repository.recipes = [recipe]
        let navigation = NotificationNavigation()
        let library = makeLibrary(repository: repository)
        library.load()
        let loadsBeforeTap = repository.fetchRecipesCallCount

        navigation.open(recipeID: recipe.id)

        XCTAssertEqual(
            navigation.claimRecipe(in: library)?.id,
            recipe.id
        )
        XCTAssertEqual(
            repository.fetchRecipesCallCount,
            loadsBeforeTap,
            "A recipe already in the loaded library needs no reload"
        )
        XCTAssertNil(navigation.recipeID)
    }

    func testBannerTapBeforeTheFirstLibraryLoadStillOpensTheRecipe() {
        let recipe = notificationRecipe()
        let repository = NotificationTestRepository()
        repository.recipes = [recipe]
        let navigation = NotificationNavigation()
        let library = makeLibrary(repository: repository)

        navigation.open(recipeID: recipe.id)

        XCTAssertEqual(library.loadState, .idle)
        XCTAssertEqual(
            navigation.claimRecipe(in: library)?.id,
            recipe.id,
            "A tap that arrives before the first load must load the"
                + " library rather than land dead"
        )
        XCTAssertNil(navigation.recipeID)
    }

    func testBannerTapConsumesTheNavigationEvenWhenTheReloadFails() {
        let repository = NotificationTestRepository()
        repository.recipes = [notificationRecipe()]
        let navigation = NotificationNavigation()
        let library = makeLibrary(repository: repository)
        library.load()

        let imported = backgroundImportedRecipe()
        repository.recipes.append(imported)
        repository.fetchRecipesError =
            NotificationTestRepositoryError.unavailable
        navigation.open(recipeID: imported.id)

        XCTAssertNil(navigation.claimRecipe(in: library))
        XCTAssertNil(
            navigation.recipeID,
            "A failed reload must not poison later notification taps"
        )
    }

    func testLibraryOpensNotificationTapsThroughTheClaimingResolver() throws {
        // The composed tests above pin the claim semantics; this pins
        // the wiring so LibraryView cannot quietly go back to the bare
        // in-memory lookup that dropped stale-library taps.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "Ladle/Library/LibraryView.swift"
                ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("notificationNavigation.claimRecipe(")
        )
    }

    private func makeLibrary(
        repository: NotificationTestRepository
    ) -> LibraryViewModel {
        LibraryViewModel(
            repository: repository,
            preferenceStore: NotificationTestPreferenceStore()
        )
    }

    private func backgroundImportedRecipe() -> Recipe {
        Recipe(
            id: UUID(
                uuidString: "7A0C21D4-93BE-4A5D-8F0E-2B85F8C4A11B"
            )!,
            title: "Background Bibimbap",
            source: .youtube,
            originalURL: URL(
                string: "https://youtu.be/notification-background"
            )!,
            servings: 2
        )
    }

    private func makeCoordinator(
        repository: NotificationTestRepository,
        outcome: ImportServiceProgress,
        notifications: TestNotificationService
    ) -> ImportCoordinator {
        ImportCoordinator(
            repository: repository,
            service: NotificationTestImportService(outcome: outcome),
            accountSession: AccountSession(
                store: NotificationTestPreferenceStore()
            ),
            clock: NotificationImmediateClock(),
            notificationService: notifications
        )
    }

    private func notificationRecipe() -> Recipe {
        Recipe(
            id: UUID(
                uuidString: "D3798F1B-5670-451D-B7F3-9FC78A85619D"
            )!,
            title: "Notification Noodles",
            source: .tiktok,
            originalURL: URL(
                string:
                    "https://www.tiktok.com/@ladle/video/notification-ready"
            )!,
            servings: 2
        )
    }
}

@MainActor
private final class TestNotificationService: NotificationService {
    let result: ImportNotificationResult
    private(set) var notifiedRecipeIDs: [UUID] = []

    init(result: ImportNotificationResult = .scheduled) {
        self.result = result
    }

    func notifyImportReady(
        recipe: Recipe
    ) async -> ImportNotificationResult {
        notifiedRecipeIDs.append(recipe.id)
        return result
    }
}

private struct NotificationTestImportService: ImportService {
    let outcome: ImportServiceProgress

    func submit(
        _ job: ImportJob,
        allowingDuplicate: Bool
    ) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(
            remoteJobID: job.id.uuidString,
            progress: outcome
        )
    }

    func status(remoteJobID: String) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(remoteJobID: remoteJobID, progress: outcome)
    }

    func retry(
        remoteJobID: String,
        correctionNotes: String?,
        pastedRecipeText: String?
    ) async throws -> ImportServiceUpdate {
        ImportServiceUpdate(remoteJobID: remoteJobID, progress: outcome)
    }
}

private struct NotificationImmediateClock: ImportClock {
    func sleep(for duration: Duration) async throws {}
}

private enum NotificationTestRepositoryError: Error {
    case unavailable
}

@MainActor
private final class NotificationTestRepository: RecipeRepository {
    var recipes: [Recipe] = []
    var importJobs: [ImportJob] = []
    var fetchRecipesError: Error?
    private(set) var fetchRecipesCallCount = 0

    func fetchRecipes() throws -> [Recipe] {
        fetchRecipesCallCount += 1
        if let fetchRecipesError {
            throw fetchRecipesError
        }
        return recipes
    }

    func fetchRecipe(id: UUID) throws -> Recipe? {
        recipes.first { $0.id == id }
    }

    func save(_ recipe: Recipe) throws {
        if let index = recipes.firstIndex(
            where: { $0.id == recipe.id }
        ) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
    }

    func deleteRecipe(id: UUID) throws {
        recipes.removeAll { $0.id == id }
    }

    func fetchImportJobs() throws -> [ImportJob] {
        importJobs
    }

    func save(_ importJob: ImportJob) throws {
        if let index = importJobs.firstIndex(
            where: { $0.id == importJob.id }
        ) {
            importJobs[index] = importJob
        } else {
            importJobs.append(importJob)
        }
    }

    func seedIfNeeded(
        recipes: [Recipe],
        importJobs: [ImportJob]
    ) throws {}
}

private final class NotificationTestPreferenceStore: PreferenceStoring {
    private var values: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}
