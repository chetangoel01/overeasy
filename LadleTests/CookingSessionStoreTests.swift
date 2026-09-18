import Foundation
import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class CookingSessionStoreTests: XCTestCase {
    // MARK: One session at a time

    func testStartingTheRecipeAlreadyCookingResumesItAtTheGivenStep() async throws {
        let context = Context()
        let recipe = Self.orzo
        context.store.start(recipe: recipe)
        let session = try XCTUnwrap(context.store.active)
        await session.startTimer(id: Self.timerID(in: recipe))
        context.store.presented = nil

        let replacement = context.store.start(
            recipe: recipe,
            stepID: recipe.orderedSteps[2].id
        )

        XCTAssertNil(replacement, "The same recipe is never a replacement")
        XCTAssertIdentical(context.store.active, session)
        XCTAssertIdentical(
            context.store.presented,
            session,
            "Starting the recipe already cooking puts it back on screen"
        )
        XCTAssertEqual(session.currentStepIndex, 2)
    }

    func testStartingAnotherRecipeWithARunningTimerAsksBeforeEndingIt() async throws {
        let context = Context()
        context.store.start(recipe: Self.orzo)
        let orzoSession = try XCTUnwrap(context.store.active)
        await orzoSession.startTimer(id: Self.timerID(in: Self.orzo))

        let replacement = context.store.start(recipe: Self.burgers)

        let asked = try XCTUnwrap(replacement)
        XCTAssertEqual(asked.activeRecipeTitle, Self.orzo.title)
        XCTAssertIdentical(
            context.store.active,
            orzoSession,
            "Nothing may end before the cook answers"
        )
        XCTAssertTrue(context.notifications.cancelled.isEmpty)
        XCTAssertNotNil(context.store.pendingReplacement)

        context.store.confirmReplacement()

        XCTAssertEqual(context.store.active?.recipe.id, Self.burgers.id)
        XCTAssertNil(context.store.pendingReplacement)
        XCTAssertEqual(
            context.notifications.cancelled,
            [Self.timerID(in: Self.orzo)],
            "Confirming ends the timers the dialog named"
        )
    }

    func testCancellingTheReplacementLeavesTheRunningSessionAlone() async {
        let context = Context()
        context.store.start(recipe: Self.orzo)
        await context.store.active?.startTimer(id: Self.timerID(in: Self.orzo))
        context.store.start(recipe: Self.burgers)

        context.store.cancelReplacement()

        XCTAssertNil(context.store.pendingReplacement)
        XCTAssertEqual(context.store.active?.recipe.id, Self.orzo.id)
        XCTAssertTrue(context.notifications.cancelled.isEmpty)
    }

    func testASessionWithNoRunningTimerIsReplacedWithoutAsking() async {
        let context = Context()
        context.store.start(recipe: Self.orzo)
        let timerID = Self.timerID(in: Self.orzo)
        await context.store.active?.startTimer(id: timerID)
        // Ran out while the cook was elsewhere: its alert has fired and
        // there is nothing left to warn about.
        context.clock.advance(by: 720)

        let replacement = context.store.start(recipe: Self.burgers)

        XCTAssertNil(
            replacement,
            "A finished timer is not a reason to interrupt the cook"
        )
        XCTAssertEqual(context.store.active?.recipe.id, Self.burgers.id)
    }

    func testDismissingTheCoverLeavesTheSessionRunningAndResumeBringsItBack() async throws {
        let context = Context()
        context.store.start(recipe: Self.orzo)
        let session = try XCTUnwrap(context.store.active)
        await session.startTimer(id: Self.timerID(in: Self.orzo))

        // What the full-screen cover does when it is dismissed.
        context.store.presented = nil

        XCTAssertIdentical(context.store.active, session)
        XCTAssertTrue(
            context.notifications.cancelled.isEmpty,
            "Leaving the cooking screen must not cancel a pending alert —"
                + " that is the bug #177 exists to fix"
        )
        XCTAssertTrue(context.store.isCooking(Self.orzo.id))

        context.store.resume()

        XCTAssertIdentical(context.store.presented, session)
    }

    func testEndingTheSessionCancelsItsAlertsAndDropsTheSnapshot() async {
        let context = Context()
        context.store.start(recipe: Self.orzo)
        let timerID = Self.timerID(in: Self.orzo)
        await context.store.active?.startTimer(id: timerID)
        XCTAssertNotNil(
            context.preferences.string(forKey: CookingSessionStore.snapshotKey)
        )

        context.store.end()

        XCTAssertNil(context.store.active)
        XCTAssertNil(context.store.presented)
        XCTAssertEqual(context.notifications.cancelled, [timerID])
        XCTAssertNil(
            context.preferences.string(forKey: CookingSessionStore.snapshotKey)
        )
    }

    // MARK: Surviving a relaunch

    func testARestoredRunningTimerCountsDownFromItsReferenceDate() async throws {
        let context = Context()
        context.store.start(recipe: Self.orzo)
        let timerID = Self.timerID(in: Self.orzo)
        await context.store.active?.startTimer(id: timerID)
        context.store.active?.moveNext()

        // The app is gone for two minutes and comes back.
        let relaunch = Context(
            preferences: context.preferences,
            now: context.clock.now.addingTimeInterval(120)
        )
        relaunch.store.restore()

        let restored = try XCTUnwrap(relaunch.store.active)
        XCTAssertEqual(restored.recipe.id, Self.orzo.id)
        XCTAssertEqual(restored.currentStepIndex, 1)
        XCTAssertEqual(restored.timerPhase(for: timerID), .running)
        XCTAssertEqual(
            restored.remainingSeconds(for: timerID),
            600,
            "A restored countdown resumes against real time, not from its"
                + " full duration"
        )
        XCTAssertNil(
            relaunch.store.presented,
            "Restoring must not push the cooking screen at the cook"
        )
    }

    func testARestoredTimerWhoseDeadlinePassedComesBackFinished() async {
        let context = Context()
        context.store.start(recipe: Self.orzo)
        let timerID = Self.timerID(in: Self.orzo)
        await context.store.active?.startTimer(id: timerID)

        let relaunch = Context(
            preferences: context.preferences,
            now: context.clock.now.addingTimeInterval(5_000)
        )
        relaunch.store.restore()

        XCTAssertEqual(
            relaunch.store.active?.timerPhase(for: timerID),
            .finished
        )
        XCTAssertEqual(relaunch.store.active?.remainingSeconds(for: timerID), 0)
    }

    func testTheScalingAndTheTickedStepsSurviveTheRelaunch() throws {
        let context = Context()
        var scaling = RecipeScaling(baseServings: 4)
        scaling.setServings(8)
        context.store.start(recipe: Self.orzo, scaling: scaling)
        context.store.active?.toggleCompletedStep(Self.orzo.orderedSteps[0].id)
        context.store.active?.enterFocusMode()

        let relaunch = Context(preferences: context.preferences)
        relaunch.store.restore()

        let restored = try XCTUnwrap(relaunch.store.active)
        XCTAssertEqual(restored.scaledYieldText, "8 servings")
        XCTAssertTrue(restored.isStepCompleted(Self.orzo.orderedSteps[0].id))
        XCTAssertEqual(restored.mode, .focus)
    }

    func testAMissingRecipeOrAnUnreadableSnapshotIsDroppedSilently() {
        for stored in ["not json at all", Self.snapshotJSON(recipeID: UUID())] {
            let preferences = MemoryPreferenceStore()
            preferences.set(stored, forKey: CookingSessionStore.snapshotKey)
            let context = Context(preferences: preferences)

            context.store.restore()

            XCTAssertNil(context.store.active)
            XCTAssertNil(
                preferences.string(forKey: CookingSessionStore.snapshotKey),
                "A snapshot that cannot be honoured is not left to be"
                    + " retried at every launch"
            )
        }
    }

    // MARK: Alerts lead back to the step

    func testACookingLinkParsesIntoTheStepItNames() {
        let recipeID = UUID()
        let stepID = UUID()
        let url = URL(
            string: "overeasy://cooking/\(recipeID.uuidString.lowercased())"
                + "/steps/\(stepID.uuidString)"
        )!

        XCTAssertEqual(
            NotificationDestination(url: url),
            .cookingStep(recipeID: recipeID, stepID: stepID, timerID: nil),
            "UUID case is not part of the contract with the Live Activity"
        )
    }

    func testLinksThatAreNotACookingStepAreIgnored() {
        for text in [
            "overeasy://cooking/not-a-uuid/steps/\(UUID().uuidString)",
            "overeasy://cooking/\(UUID().uuidString)",
            "overeasy://recipes/\(UUID().uuidString)/steps/\(UUID().uuidString)",
            "https://overeasy.app/cooking/\(UUID().uuidString)"
                + "/steps/\(UUID().uuidString)",
        ] {
            XCTAssertNil(
                NotificationDestination(url: URL(string: text)!),
                "\(text) is not a cooking link"
            )
        }
    }

    func testATimerAlertCarriesTheStepAndAnImportAlertStillCarriesTheRecipe() {
        let recipeID = UUID()
        let stepID = UUID()
        let timerID = UUID()

        XCTAssertEqual(
            NotificationDestination(userInfo: [
                "recipeID": recipeID.uuidString,
                "stepID": stepID.uuidString,
                "timerID": timerID.uuidString,
            ]),
            .cookingStep(
                recipeID: recipeID,
                stepID: stepID,
                timerID: timerID
            )
        )
        XCTAssertEqual(
            NotificationDestination(userInfo: ["recipeID": recipeID.uuidString]),
            .recipe(recipeID)
        )
        XCTAssertNil(NotificationDestination(userInfo: [:]))
    }

    func testATappedTimerAlertMovesTheRunningSessionToItsStep() async throws {
        let context = Context()
        context.store.start(recipe: Self.orzo)
        let session = try XCTUnwrap(context.store.active)
        await session.startTimer(id: Self.timerID(in: Self.orzo))
        context.store.presented = nil

        context.store.open(
            .cookingStep(
                recipeID: Self.orzo.id,
                stepID: Self.orzo.orderedSteps[1].id,
                timerID: Self.timerID(in: Self.orzo)
            )
        )

        XCTAssertIdentical(context.store.active, session)
        XCTAssertIdentical(context.store.presented, session)
        XCTAssertEqual(session.currentStepIndex, 1)
    }

    func testATappedTimerAlertWithNoSessionStartsOneAtThatStep() {
        let context = Context()

        context.store.open(
            .cookingStep(
                recipeID: Self.orzo.id,
                stepID: Self.orzo.orderedSteps[1].id,
                timerID: nil
            )
        )

        XCTAssertEqual(context.store.active?.recipe.id, Self.orzo.id)
        XCTAssertEqual(context.store.active?.currentStepIndex, 1)
        XCTAssertNotNil(context.store.presented)
    }

    func testATappedTimerAlertForAnotherRecipeStillAsksBeforeReplacing() async {
        let context = Context()
        context.store.start(recipe: Self.orzo)
        await context.store.active?.startTimer(id: Self.timerID(in: Self.orzo))

        context.store.open(
            .cookingStep(
                recipeID: Self.burgers.id,
                stepID: Self.burgers.orderedSteps[1].id,
                timerID: nil
            )
        )

        XCTAssertEqual(
            context.store.pendingReplacement?.activeRecipeTitle,
            Self.orzo.title
        )
        XCTAssertEqual(context.store.active?.recipe.id, Self.orzo.id)
    }

    // MARK: Fixtures

    private static let burgers = PreviewFixtures.recipes[0]
    private static let orzo = PreviewFixtures.recipes[1]

    private static func timerID(in recipe: Recipe) -> UUID {
        recipe.orderedSteps.flatMap(\.timers)[0].id
    }

    private static func snapshotJSON(recipeID: UUID) -> String {
        let snapshot = CookingSessionSnapshot(
            recipeID: recipeID,
            baseServings: nil,
            servings: nil,
            session: CookingSession(stepIDs: []),
            timers: []
        )
        let data = (try? JSONEncoder().encode(snapshot)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""

    }

    /// A store wired to a fake clock, a fake scheduler and an in-memory
    /// preference store, so a second `Context` over the same preferences is
    /// the next launch.
    @MainActor
    private final class Context {
        let clock: TestCookingClock
        let preferences: MemoryPreferenceStore
        let notifications: TestTimerNotificationScheduler
        let store: CookingSessionStore

        init(
            preferences: MemoryPreferenceStore = MemoryPreferenceStore(),
            now: Date = Date(timeIntervalSince1970: 1_000)
        ) {
            let clock = TestCookingClock(now: now)
            let notifications = TestTimerNotificationScheduler()
            self.clock = clock
            self.notifications = notifications
            self.preferences = preferences
            store = CookingSessionStore(
                snapshots: preferences,
                findRecipe: { id in
                    PreviewFixtures.recipes.first { $0.id == id }
                },
                makeViewModel: { recipe, scaling in
                    CookingViewModel(
                        recipe: recipe,
                        scaling: scaling,
                        clock: clock,
                        notificationScheduler: notifications,
                        screenAwakeController: ScreenAwakeController(
                            idleTimer: TestIdleTimerController()
                        )
                    )
                },
                clock: clock
            )
        }
    }
}

final class MemoryPreferenceStore: PreferenceStoring {
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
        values[defaultName] = nil
    }
}
