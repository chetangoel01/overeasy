import Foundation
import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class CookingViewModelTests: XCTestCase {
    func testModeSwitchingSharesCurrentStepAndCompletionState() {
        let recipe = PreviewFixtures.recipes[1]
        let viewModel = makeViewModel(recipe: recipe)
        let firstStep = recipe.orderedSteps[0]
        let firstIngredient = recipe.orderedIngredients[0]

        viewModel.moveNext()
        viewModel.toggleCompletedStep(firstStep.id)
        viewModel.toggleCompletedIngredient(firstIngredient.id)
        viewModel.enterFocusMode()

        XCTAssertEqual(viewModel.mode, .focus)
        XCTAssertEqual(viewModel.currentStepIndex, 1)
        XCTAssertTrue(viewModel.isStepCompleted(firstStep.id))
        XCTAssertTrue(
            viewModel.isIngredientCompleted(firstIngredient.id)
        )

        viewModel.exitFocusMode()

        XCTAssertEqual(viewModel.mode, .fullRecipe)
        XCTAssertEqual(viewModel.currentStepIndex, 1)
        XCTAssertTrue(viewModel.isStepCompleted(firstStep.id))
    }

    func testNavigationClampsAndRelevantIngredientsFollowCurrentStep() {
        let recipe = PreviewFixtures.recipes[1]
        let viewModel = makeViewModel(recipe: recipe)

        viewModel.movePrevious()
        XCTAssertEqual(viewModel.currentStepIndex, 0)
        XCTAssertEqual(
            viewModel.relevantIngredients.map(\.name),
            ["orzo", "garlic"]
        )

        for _ in 0...recipe.steps.count {
            viewModel.moveNext()
        }

        XCTAssertEqual(
            viewModel.currentStepIndex,
            recipe.orderedSteps.count - 1
        )
        XCTAssertEqual(
            viewModel.relevantIngredients.map(\.name),
            ["crumbled feta", "extra-virgin olive oil"]
        )
    }

    func testTimerStartsPausesResumesAndResetsFromInjectedClock() async throws {
        let recipe = PreviewFixtures.recipes[1]
        let detectedTimer = try XCTUnwrap(
            recipe.orderedSteps[1].timers.first
        )
        let clock = TestCookingClock(
            now: Date(timeIntervalSince1970: 10_000)
        )
        let notifications = TestTimerNotificationScheduler()
        let viewModel = makeViewModel(
            recipe: recipe,
            clock: clock,
            notifications: notifications
        )

        await viewModel.startTimer(id: detectedTimer.id)
        XCTAssertEqual(
            viewModel.timer(id: detectedTimer.id)?.phase,
            .running
        )
        XCTAssertEqual(
            notifications.scheduled.last?.durationSeconds,
            720
        )

        clock.advance(by: 30)
        viewModel.pauseTimer(id: detectedTimer.id)
        XCTAssertEqual(
            viewModel.timer(id: detectedTimer.id)?.phase,
            .paused
        )
        XCTAssertEqual(
            viewModel.remainingSeconds(for: detectedTimer.id),
            690
        )
        XCTAssertEqual(notifications.cancelled.last, detectedTimer.id)

        clock.advance(by: 40)
        await viewModel.startTimer(id: detectedTimer.id)
        XCTAssertEqual(
            notifications.scheduled.last?.durationSeconds,
            690
        )

        viewModel.resetTimer(id: detectedTimer.id)
        XCTAssertEqual(
            viewModel.timer(id: detectedTimer.id)?.phase,
            .idle
        )
        XCTAssertEqual(
            viewModel.remainingSeconds(for: detectedTimer.id),
            720
        )
    }

    func testTimerDoesNotScheduleNotificationUntilExplicitStart() throws {
        let recipe = PreviewFixtures.recipes[1]
        let detectedTimer = try XCTUnwrap(
            recipe.orderedSteps[1].timers.first
        )
        let notifications = TestTimerNotificationScheduler()
        let viewModel = makeViewModel(
            recipe: recipe,
            notifications: notifications
        )

        XCTAssertTrue(notifications.scheduled.isEmpty)
        XCTAssertEqual(
            viewModel.remainingSeconds(for: detectedTimer.id),
            detectedTimer.durationSeconds
        )
    }

    func testPausingWhileNotificationSchedulesCancelsStaleRequest() async throws {
        let recipe = PreviewFixtures.recipes[1]
        let detectedTimer = try XCTUnwrap(
            recipe.orderedSteps[1].timers.first
        )
        let notifications = GateTimerNotificationScheduler()
        let viewModel = makeViewModel(
            recipe: recipe,
            notifications: notifications
        )

        let start = Task {
            await viewModel.startTimer(id: detectedTimer.id)
        }
        await notifications.waitUntilScheduling()
        viewModel.pauseTimer(id: detectedTimer.id)
        notifications.release()
        await start.value

        XCTAssertEqual(
            viewModel.timer(id: detectedTimer.id)?.phase,
            .paused
        )
        XCTAssertEqual(
            notifications.cancelled,
            [detectedTimer.id, detectedTimer.id]
        )
    }

    func testRunningTimerReportsFinishedWhenCountdownReachesZero() async throws {
        let recipe = PreviewFixtures.recipes[1]
        let detectedTimer = try XCTUnwrap(
            recipe.orderedSteps[1].timers.first
        )
        let clock = TestCookingClock()
        let viewModel = makeViewModel(
            recipe: recipe,
            clock: clock
        )

        viewModel.moveNext()
        await viewModel.startTimer(id: detectedTimer.id)
        clock.advance(
            by: TimeInterval(detectedTimer.durationSeconds)
        )

        XCTAssertEqual(
            viewModel.timerPhase(for: detectedTimer.id),
            .finished
        )
        XCTAssertEqual(
            viewModel.remainingSeconds(for: detectedTimer.id),
            0
        )
        XCTAssertEqual(
            viewModel.finishedTimerForCurrentStep?.id,
            detectedTimer.id
        )

        viewModel.resetTimer(id: detectedTimer.id)
        XCTAssertNil(viewModel.finishedTimerForCurrentStep)
    }

    func testEndCookingCancelsEveryPendingTimerNotification() async throws {
        let recipe = PreviewFixtures.recipes[3]
        let timerIDs = recipe.orderedSteps.flatMap(\.timers).map(\.id)
        XCTAssertEqual(timerIDs.count, 2)
        let notifications = TestTimerNotificationScheduler()
        let viewModel = makeViewModel(
            recipe: recipe,
            notifications: notifications
        )

        viewModel.beginCooking()
        for timerID in timerIDs {
            await viewModel.startTimer(id: timerID)
        }
        viewModel.pauseTimer(id: timerIDs[1])
        XCTAssertEqual(notifications.scheduled.count, 2)
        XCTAssertEqual(notifications.cancelled, [timerIDs[1]])

        viewModel.endCooking()

        XCTAssertTrue(
            Set(notifications.cancelled).isSuperset(of: Set(timerIDs)),
            "Ending the session must cancel the running timer's pending"
                + " notification, not just the paused one's"
        )
    }

    func testEndCookingWithNothingStartedSchedulesNothing() {
        let recipe = PreviewFixtures.recipes[1]
        let notifications = TestTimerNotificationScheduler()
        let viewModel = makeViewModel(
            recipe: recipe,
            notifications: notifications
        )

        viewModel.beginCooking()
        viewModel.endCooking()

        XCTAssertTrue(notifications.scheduled.isEmpty)
    }

    func testEndCookingOnARecipeWithoutTimersCancelsNothing() {
        let recipe = PreviewFixtures.recipes[4]
        XCTAssertTrue(recipe.orderedSteps.allSatisfy(\.timers.isEmpty))
        let notifications = TestTimerNotificationScheduler()
        let viewModel = makeViewModel(
            recipe: recipe,
            notifications: notifications
        )

        viewModel.beginCooking()
        viewModel.endCooking()

        XCTAssertTrue(notifications.scheduled.isEmpty)
        XCTAssertTrue(notifications.cancelled.isEmpty)
    }

    func testKeepAwakeIsExplicitAndRestoresPreviousSettingOnExit() {
        let idleTimer = TestIdleTimerController()
        idleTimer.isIdleTimerDisabled = false
        let awakeController = ScreenAwakeController(
            idleTimer: idleTimer
        )
        let viewModel = makeViewModel(
            screenAwakeController: awakeController
        )

        viewModel.beginCooking()
        XCTAssertFalse(idleTimer.isIdleTimerDisabled)

        viewModel.setKeepsScreenAwake(true)
        XCTAssertTrue(idleTimer.isIdleTimerDisabled)

        viewModel.endCooking()
        XCTAssertFalse(idleTimer.isIdleTimerDisabled)
        XCTAssertFalse(viewModel.keepsScreenAwake)
    }

    private func makeViewModel(
        recipe: Recipe = PreviewFixtures.recipes[1],
        clock: CookingClock = TestCookingClock(),
        notifications: TimerNotificationScheduling =
            TestTimerNotificationScheduler(),
        screenAwakeController: ScreenAwakeController =
            ScreenAwakeController(
                idleTimer: TestIdleTimerController()
            )
    ) -> CookingViewModel {
        CookingViewModel(
            recipe: recipe,
            clock: clock,
            notificationScheduler: notifications,
            screenAwakeController: screenAwakeController
        )
    }
}

@MainActor
private final class TestCookingClock: CookingClock {
    var now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_000)) {
        self.now = now
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

@MainActor
private final class TestTimerNotificationScheduler:
    TimerNotificationScheduling
{
    struct Scheduled: Equatable {
        let timerID: UUID
        let label: String
        let durationSeconds: Int
    }

    private(set) var scheduled: [Scheduled] = []
    private(set) var cancelled: [UUID] = []

    func schedule(
        timerID: UUID,
        label: String,
        durationSeconds: Int
    ) async {
        scheduled.append(
            Scheduled(
                timerID: timerID,
                label: label,
                durationSeconds: durationSeconds
            )
        )
    }

    func cancel(timerID: UUID) {
        cancelled.append(timerID)
    }
}

@MainActor
private final class GateTimerNotificationScheduler:
    TimerNotificationScheduling
{
    private var isScheduling = false
    private var schedulingContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var cancelled: [UUID] = []

    func schedule(
        timerID: UUID,
        label: String,
        durationSeconds: Int
    ) async {
        isScheduling = true
        schedulingContinuation?.resume()
        schedulingContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func cancel(timerID: UUID) {
        cancelled.append(timerID)
    }

    func waitUntilScheduling() async {
        guard !isScheduling else {
            return
        }
        await withCheckedContinuation { continuation in
            schedulingContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class TestIdleTimerController: IdleTimerControlling {
    var isIdleTimerDisabled = false
}
