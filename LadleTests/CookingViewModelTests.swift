import Foundation
import LadleCore
import UserNotifications
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
        XCTAssertTrue(viewModel.showsStepIngredientAmounts)
        viewModel.showsStepIngredientAmounts = false

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

        // The fold is the cook's for the session: another step, and the
        // trip through Full Recipe, leave it how they left it.
        viewModel.enterFocusMode()
        viewModel.moveNext()
        XCTAssertFalse(viewModel.showsStepIngredientAmounts)
    }

    func testNavigationClampsAndRelevantIngredientsFollowCurrentStep() {
        let recipe = PreviewFixtures.recipes[1]
        let viewModel = makeViewModel(recipe: recipe)

        viewModel.movePrevious()
        XCTAssertEqual(viewModel.currentStepIndex, 0)
        XCTAssertEqual(
            viewModel.stepIngredients.map(\.ingredient.name),
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
            viewModel.stepIngredients.map(\.ingredient.name),
            ["crumbled feta", "extra-virgin olive oil"]
        )
    }

    /// Focus Mode prints each amount at the session's serving count. An
    /// amount belongs to the whole recipe and is never split between steps,
    /// so a row has to know which other steps share its ingredient.
    func testStepIngredientsCarryScaledAmountsAndTheOtherStepsSharingThem() {
        let recipe = PreviewFixtures.recipes[3]
        var scaling = RecipeScaling(baseServings: recipe.servings)
        scaling.setServings(recipe.servings * 2)
        let viewModel = makeViewModel(recipe: recipe, scaling: scaling)

        viewModel.moveNext()

        // Step 2 roasts the thighs that steps 1 and 3 also handle, over
        // scallions no other step touches.
        XCTAssertEqual(
            viewModel.stepIngredients.map(\.amount),
            ["4 lb", "2 bunch"]
        )
        XCTAssertEqual(
            viewModel.stepIngredients.map(\.otherStepNumbers),
            [[1, 3], []]
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

    func testFinishingDuringPermissionPromptDoesNotCancelCompletionAlert() async throws {
        let recipe = PreviewFixtures.recipes[1]
        let timer = try XCTUnwrap(recipe.orderedSteps[1].timers.first)
        let clock = TestCookingClock()
        let notifications = GateTimerNotificationScheduler()
        let viewModel = makeViewModel(recipe: recipe, clock: clock, notifications: notifications)
        let start = Task { await viewModel.startTimer(id: timer.id) }
        await notifications.waitUntilScheduling()
        clock.advance(by: TimeInterval(timer.durationSeconds))
        notifications.release()
        await start.value
        XCTAssertEqual(viewModel.timerPhase(for: timer.id), .finished)
        XCTAssertTrue(notifications.cancelled.isEmpty)
    }

    func testCompletionRequestLeadsBackToItsStepAndKeepsDeadlineAcrossPermissionDelay() async throws {
        for delay in [0.0, 4.0, 15.0] {
            let clock = TestCookingClock()
            let center = RecordingTimerNotificationCenter {
                clock.advance(by: delay)
            }
            let tone = UNNotificationSound(named: UNNotificationSoundName("tone.caf"))
            let scheduler = LocalTimerNotificationScheduler(
                center: center,
                now: { clock.now },
                sound: { tone }
            )
            let notification = simmerNotification()
            await scheduler.schedule(notification)
            let request = try XCTUnwrap(center.requests.first)
            XCTAssertEqual(center.options, [.alert, .sound])
            XCTAssertEqual(request.content.title, "Simmer is ready")
            XCTAssertEqual(request.content.body, "Beef stew, step 3.")
            XCTAssertEqual(request.content.sound, tone)
            // A Focus must not swallow a timer the cook is waiting on.
            XCTAssertEqual(request.content.interruptionLevel, .timeSensitive)
            XCTAssertEqual(
                request.content.userInfo["recipeID"] as? String,
                notification.recipeID.uuidString
            )
            XCTAssertEqual(
                request.content.userInfo["stepID"] as? String,
                notification.stepID.uuidString
            )
            XCTAssertEqual(
                request.content.userInfo["timerID"] as? String,
                notification.timerID.uuidString
            )
            if delay < 10 {
                let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
                XCTAssertEqual(trigger.timeInterval, 10 - delay, accuracy: 0.01)
                XCTAssertFalse(trigger.repeats)
            } else {
                XCTAssertNil(request.trigger, "An elapsed timer should alert immediately after permission is granted")
            }
        }
    }

    func testDeniedOrCancelledPermissionDoesNotLeaveATimerAlert() async {
        for denied in [true, false] {
            let timerID = UUID()
            var scheduler: LocalTimerNotificationScheduler?
            let center = RecordingTimerNotificationCenter {
                if !denied { scheduler?.cancel(timerID: timerID) }
            }
            center.authorized = !denied
            scheduler = LocalTimerNotificationScheduler(center: center)
            await scheduler?.schedule(simmerNotification(timerID: timerID))
            XCTAssertTrue(center.requests.isEmpty)
        }
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

    func testLeavingTheScreenKeepsTimersAndEndingTheSessionCancelsThem() async throws {
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

        // Leaving the screen is not ending the session any more: the
        // timers a cook walked away from keep running.
        viewModel.endCooking()
        XCTAssertEqual(notifications.cancelled, [timerIDs[1]])

        viewModel.endSession()

        XCTAssertTrue(
            Set(notifications.cancelled).isSuperset(of: Set(timerIDs)),
            "Ending the session must cancel the running timer's pending"
                + " notification, not just the paused one's"
        )
    }

    /// The Lock Screen copy of a timer moves with the timer itself: one
    /// activity per start, the frozen remainder on a pause, the new deadline
    /// on a resume, and nothing left behind by a reset.
    func testTheLockScreenTimerFollowsStartPauseResumeAndReset() async throws {
        let recipe = PreviewFixtures.recipes[1]
        let step = recipe.orderedSteps[1]
        let detectedTimer = try XCTUnwrap(step.timers.first)
        let start = Date(timeIntervalSince1970: 1_000)
        let clock = TestCookingClock(now: start)
        let activities = TestTimerActivityPresenter()
        let viewModel = makeViewModel(
            recipe: recipe,
            clock: clock,
            activities: activities
        )

        await viewModel.startTimer(id: detectedTimer.id)
        clock.advance(by: 30)
        viewModel.pauseTimer(id: detectedTimer.id)
        clock.advance(by: 40)
        await viewModel.startTimer(id: detectedTimer.id)
        viewModel.resetTimer(id: detectedTimer.id)

        XCTAssertEqual(
            activities.calls,
            [
                .start(
                    timerID: detectedTimer.id,
                    stepID: step.id,
                    endDate: start.addingTimeInterval(720)
                ),
                .pause(timerID: detectedTimer.id, remainingSeconds: 690),
                // Resumed 70 seconds after the start, with 690 left to run.
                .start(
                    timerID: detectedTimer.id,
                    stepID: step.id,
                    endDate: start.addingTimeInterval(760)
                ),
                .end(timerID: detectedTimer.id),
            ]
        )
    }

    /// Asking for notification permission can outlast the cook's patience.
    /// The activity has to be requested before that await, or a timer paused
    /// while the prompt is up comes back to the Lock Screen still running.
    func testPausingWhileTheNotificationSchedulesLeavesThePauseOnTheLockScreen()
        async throws
    {
        let recipe = PreviewFixtures.recipes[1]
        let detectedTimer = try XCTUnwrap(
            recipe.orderedSteps[1].timers.first
        )
        let notifications = GateTimerNotificationScheduler()
        let activities = TestTimerActivityPresenter()
        let viewModel = makeViewModel(
            recipe: recipe,
            notifications: notifications,
            activities: activities
        )

        let start = Task {
            await viewModel.startTimer(id: detectedTimer.id)
        }
        await notifications.waitUntilScheduling()
        viewModel.pauseTimer(id: detectedTimer.id)
        notifications.release()
        await start.value

        XCTAssertEqual(
            activities.calls.last,
            .pause(timerID: detectedTimer.id, remainingSeconds: 720)
        )
        XCTAssertEqual(activities.calls.count, 2)
    }

    func testEndingTheSessionTakesEveryTimerOffTheLockScreen() async throws {
        let recipe = PreviewFixtures.recipes[3]
        let timerIDs = recipe.orderedSteps.flatMap(\.timers).map(\.id)
        let activities = TestTimerActivityPresenter()
        let viewModel = makeViewModel(
            recipe: recipe,
            activities: activities
        )

        viewModel.beginCooking()
        for timerID in timerIDs {
            await viewModel.startTimer(id: timerID)
        }

        // Leaving the screen is not ending the session: those timers keep
        // running, and so do their Lock Screen copies.
        viewModel.endCooking()
        XCTAssertFalse(activities.calls.contains(.endAll))

        viewModel.endSession()

        XCTAssertEqual(
            activities.calls.filter { $0 == .endAll },
            [.endAll]
        )
        XCTAssertEqual(activities.calls.last, .endAll)
    }

    func testAFinishedTimerIsReportedToTheLockScreenOnce() async throws {
        let recipe = PreviewFixtures.recipes[1]
        let detectedTimer = try XCTUnwrap(
            recipe.orderedSteps[1].timers.first
        )
        let clock = TestCookingClock()
        let activities = TestTimerActivityPresenter()
        let viewModel = makeViewModel(
            recipe: recipe,
            clock: clock,
            activities: activities
        )

        await viewModel.startTimer(id: detectedTimer.id)
        clock.advance(by: TimeInterval(detectedTimer.durationSeconds))
        viewModel.timerDidFinish(id: detectedTimer.id)

        XCTAssertEqual(
            activities.calls.filter { $0 == .finish(timerID: detectedTimer.id) },
            [.finish(timerID: detectedTimer.id)]
        )
    }

    /// The tap destination is a contract with the deep link in #177, and the
    /// step a timer belongs to is what makes it resolvable.
    func testAnActivityCarriesItsStepAndTheCookingTapDestination() throws {
        let recipe = PreviewFixtures.recipes[1]
        let step = recipe.orderedSteps[1]
        let detectedTimer = try XCTUnwrap(step.timers.first)

        let attributes = CookingTimerActivityAttributes(
            timer: RecipeTimer(detectedTimer),
            recipe: recipe,
            stepID: step.id,
            stepIndex: 1
        )

        XCTAssertEqual(attributes.recipeID, recipe.id)
        XCTAssertEqual(attributes.recipeTitle, recipe.title)
        XCTAssertEqual(attributes.stepID, step.id)
        XCTAssertEqual(attributes.stepIndex, 1)
        XCTAssertEqual(attributes.timerID, detectedTimer.id)
        XCTAssertEqual(attributes.label, detectedTimer.label)
        XCTAssertEqual(attributes.durationSeconds, 720)
        XCTAssertEqual(
            attributes.stepURL?.absoluteString,
            "overeasy://cooking/\(recipe.id.uuidString.lowercased())"
                + "/steps/\(step.id.uuidString.lowercased())"
        )
    }

    /// Nothing of the app's runs when a backgrounded timer reaches zero, so
    /// the finished appearance has to be readable from the content alone.
    func testALockScreenTimerReadsItsOwnFinishFromTheDeadline() {
        let now = Date(timeIntervalSince1970: 1_000)
        let deadline = now.addingTimeInterval(60)
        let running = CookingTimerActivityAttributes.ContentState.running(
            endDate: deadline,
            remainingSeconds: 60
        )

        XCTAssertEqual(
            CookingTimerAppearance(state: running, isStale: false, now: now),
            .running(deadline: deadline)
        )
        // The system marks the activity stale at the deadline the app set,
        // which is the only finish a suspended app can deliver.
        XCTAssertEqual(
            CookingTimerAppearance(state: running, isStale: true, now: now),
            .finished
        )
        XCTAssertEqual(
            CookingTimerAppearance(
                state: .running(
                    endDate: now.addingTimeInterval(-1),
                    remainingSeconds: 0
                ),
                isStale: false,
                now: now
            ),
            .finished
        )
        XCTAssertEqual(
            CookingTimerAppearance(
                state: .paused(remainingSeconds: 90),
                isStale: false,
                now: now
            ),
            .paused(remainingSeconds: 90)
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
        viewModel.endSession()

        XCTAssertTrue(notifications.scheduled.isEmpty)
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

    func testTimerButtonFeedbackSitsInsideTheTimelineRefresh() throws {
        // Timer completion is purely time-derived: the stored phase never
        // mutates to .finished, so nothing re-evaluates the button's own
        // body at 0:00. Only the TimelineView's per-second content refresh
        // observes the .running -> .finished transition — a sensoryFeedback
        // modifier attached outside it keeps a stale trigger forever and
        // the finish haptic never fires. The modifiers must therefore sit
        // inside the TimelineView's content, which its static body type
        // proves.
        let recipe = PreviewFixtures.recipes[1]
        let detectedTimer = try XCTUnwrap(
            recipe.orderedSteps[1].timers.first
        )
        let button = RecipeTimerButton(
            viewModel: makeViewModel(recipe: recipe),
            detectedTimer: detectedTimer
        )

        let structure = String(describing: type(of: button.body))
        let timelineSpan = try XCTUnwrap(
            Self.genericSpan(of: "TimelineView", in: structure),
            "RecipeTimerButton must keep its per-second TimelineView"
        )
        let feedbackSites = Self.occurrences(
            of: "FeedbackGenerator<RecipeTimerPhase>",
            in: structure
        )
        XCTAssertEqual(
            feedbackSites.count,
            3,
            "Expected the started, paused, and finished feedback"
                + " modifiers in \(structure)"
        )
        for site in feedbackSites {
            XCTAssertTrue(
                timelineSpan.contains(site),
                "Every timer feedback trigger must be re-read by the"
                    + " TimelineView refresh, but one sits outside it"
                    + " in \(structure)"
            )
        }
    }

    /// The range spanned by `name`'s generic parameter list in a type
    /// description, angle brackets balanced (`->` ignored).
    private static func genericSpan(
        of name: String,
        in description: String
    ) -> Range<String.Index>? {
        guard let start = description.range(of: "\(name)<") else {
            return nil
        }
        var depth = 0
        var previous: Character = " "
        var index = description.index(before: start.upperBound)
        while index < description.endIndex {
            let character = description[index]
            if character == "<" {
                depth += 1
            } else if character == ">", previous != "-" {
                depth -= 1
                if depth == 0 {
                    return start.upperBound ..< index
                }
            }
            previous = character
            index = description.index(after: index)
        }
        return nil
    }

    private static func occurrences(
        of needle: String,
        in description: String
    ) -> [String.Index] {
        var found: [String.Index] = []
        var searchStart = description.startIndex
        while let range = description.range(
            of: needle,
            range: searchStart ..< description.endIndex
        ) {
            found.append(range.lowerBound)
            searchStart = range.upperBound
        }
        return found
    }

    /// Cook mode is opened from the recipe page and built from what that page
    /// is showing, so the count the cook chose there comes with it. There is
    /// no control on this screen and nothing is stored, so a session carries
    /// the snapshot it was started with.
    func testAScaledSessionCooksTheScaledAmounts() {
        let recipe = PreviewFixtures.recipes[0]
        var scaling = RecipeScaling(baseServings: recipe.servings)
        scaling.setServings(recipe.servings * 2)
        let viewModel = makeViewModel(recipe: recipe, scaling: scaling)

        XCTAssertEqual(viewModel.multiplier, 2)
        XCTAssertEqual(viewModel.scaledYieldText, "8 servings")
        XCTAssertEqual(
            recipe.orderedIngredients[0]
                .cookingDetailText(scaledBy: viewModel.multiplier ?? 1),
            "2 lb ground beef — 80/20, in four loose balls"
        )
    }

    func testAnUnscaledSessionCooksTheRecipeAsWritten() {
        let viewModel = makeViewModel(
            scaling: RecipeScaling(baseServings: 4)
        )

        XCTAssertNil(viewModel.multiplier)
        XCTAssertNil(viewModel.scaledYieldText)
    }

    private func simmerNotification(
        timerID: UUID = UUID()
    ) -> TimerNotification {
        TimerNotification(
            timerID: timerID,
            label: "Simmer",
            durationSeconds: 10,
            recipeID: UUID(),
            recipeTitle: "Beef stew",
            stepID: UUID(),
            stepNumber: 3
        )
    }

    private func makeViewModel(
        recipe: Recipe = PreviewFixtures.recipes[1],
        scaling: RecipeScaling? = nil,
        clock: CookingClock = TestCookingClock(),
        notifications: TimerNotificationScheduling =
            TestTimerNotificationScheduler(),
        screenAwakeController: ScreenAwakeController =
            ScreenAwakeController(
                idleTimer: TestIdleTimerController()
            ),
        activities: any TimerActivityPresenting =
            TestTimerActivityPresenter()
    ) -> CookingViewModel {
        CookingViewModel(
            recipe: recipe,
            scaling: scaling,
            clock: clock,
            notificationScheduler: notifications,
            screenAwakeController: screenAwakeController,
            activityPresenter: activities
        )
    }
}

@MainActor
final class TestCookingClock: CookingClock {
    var now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_000)) {
        self.now = now
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

@MainActor
final class TestTimerNotificationScheduler:
    TimerNotificationScheduling
{
    private(set) var scheduled: [TimerNotification] = []
    private(set) var cancelled: [UUID] = []

    func schedule(_ notification: TimerNotification) async {
        scheduled.append(notification)
    }

    func cancel(timerID: UUID) {
        cancelled.append(timerID)
    }
}

@MainActor
final class TestTimerActivityPresenter: TimerActivityPresenting {
    enum Call: Equatable {
        case start(timerID: UUID, stepID: UUID, endDate: Date)
        case adopt(runningTimerIDs: Set<UUID>)
        case pause(timerID: UUID, remainingSeconds: Int)
        case finish(timerID: UUID)
        case end(timerID: UUID)
        case endAll
        case endFinished(now: Date)
    }

    private(set) var calls: [Call] = []

    func start(
        _ timer: RecipeTimer,
        in recipe: Recipe,
        stepID: UUID,
        stepIndex: Int,
        endDate: Date
    ) {
        calls.append(
            .start(timerID: timer.id, stepID: stepID, endDate: endDate)
        )
    }

    func adoptActivities(forRunningTimers timerIDs: Set<UUID>) {
        calls.append(.adopt(runningTimerIDs: timerIDs))
    }

    func pause(timerID: UUID, remainingSeconds: Int) {
        calls.append(
            .pause(timerID: timerID, remainingSeconds: remainingSeconds)
        )
    }

    func finish(timerID: UUID) {
        calls.append(.finish(timerID: timerID))
    }

    func end(timerID: UUID) {
        calls.append(.end(timerID: timerID))
    }

    func endAll() {
        calls.append(.endAll)
    }

    func endFinished(now: Date) {
        calls.append(.endFinished(now: now))
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

    func schedule(_ notification: TimerNotification) async {
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
final class TestIdleTimerController: IdleTimerControlling {
    var isIdleTimerDisabled = false
}


@MainActor
final class RecordingTimerNotificationCenter: CookingNotificationCenter {
    let authorize: () -> Void
    var options: UNAuthorizationOptions = []
    var authorized = true
    var requests: [UNNotificationRequest] = []
    init(authorize: @escaping () -> Void) { self.authorize = authorize }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        self.options = options
        authorize()
        return authorized
    }
    func add(_ request: UNNotificationRequest) async throws { requests.append(request) }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        requests.removeAll { identifiers.contains($0.identifier) }
    }
}
