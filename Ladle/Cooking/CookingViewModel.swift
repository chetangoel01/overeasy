import Foundation
import LadleCore
import Observation

@MainActor
@Observable
final class CookingViewModel: Identifiable {
    let id = UUID()
    let recipe: Recipe
    private(set) var session: CookingSession
    private(set) var timers: [UUID: RecipeTimer]
    private(set) var keepsScreenAwake = false

    @ObservationIgnored
    private let clock: CookingClock

    @ObservationIgnored
    private let notificationScheduler: TimerNotificationScheduling

    @ObservationIgnored
    private let screenAwakeController: ScreenAwakeController

    init(
        recipe: Recipe,
        clock: CookingClock = SystemCookingClock(),
        notificationScheduler: TimerNotificationScheduling =
            LocalTimerNotificationScheduler(),
        screenAwakeController: ScreenAwakeController =
            ScreenAwakeController()
    ) {
        self.recipe = recipe
        self.clock = clock
        self.notificationScheduler = notificationScheduler
        self.screenAwakeController = screenAwakeController
        session = CookingSession(
            stepIDs: recipe.orderedSteps.map(\.id)
        )
        timers = Dictionary(
            uniqueKeysWithValues: recipe.orderedSteps
                .flatMap(\.timers)
                .map { ($0.id, RecipeTimer($0)) }
        )
    }

    var mode: CookingMode {
        session.mode
    }

    var currentStepIndex: Int {
        session.currentStepIndex
    }

    var currentStep: RecipeStep? {
        guard recipe.orderedSteps.indices.contains(currentStepIndex) else {
            return nil
        }
        return recipe.orderedSteps[currentStepIndex]
    }

    var relevantIngredients: [Ingredient] {
        guard let currentStep else {
            return []
        }
        let ingredientIDs = Set(currentStep.ingredientIDs)
        return recipe.orderedIngredients.filter {
            ingredientIDs.contains($0.id)
        }
    }

    var finishedTimerForCurrentStep: DetectedTimer? {
        currentStep?.timers.first {
            timerPhase(for: $0.id) == .finished
        }
    }

    var progressText: String {
        guard !recipe.orderedSteps.isEmpty else {
            return "No steps"
        }
        return "Step \(currentStepIndex + 1) of \(recipe.orderedSteps.count)"
    }

    var progress: Double {
        guard !recipe.orderedSteps.isEmpty else {
            return 0
        }
        return Double(currentStepIndex + 1)
            / Double(recipe.orderedSteps.count)
    }

    var canMovePrevious: Bool {
        currentStepIndex > 0
    }

    var canMoveNext: Bool {
        currentStepIndex < recipe.orderedSteps.count - 1
    }

    func beginCooking() {
        screenAwakeController.beginScope()
    }

    func endCooking() {
        screenAwakeController.endScope()
        keepsScreenAwake = false
        // The session's pending timer notifications must die with it: the
        // scheduler holding their request identifiers is deallocated with
        // this view model, so anything left pending could never be
        // cancelled again and would fire for an abandoned session.
        for timerID in timers.keys {
            notificationScheduler.cancel(timerID: timerID)
        }
    }

    func setKeepsScreenAwake(_ keepsScreenAwake: Bool) {
        self.keepsScreenAwake = keepsScreenAwake
        screenAwakeController.setKeepsScreenAwake(keepsScreenAwake)
    }

    func enterFocusMode() {
        session.setMode(.focus)
    }

    func exitFocusMode() {
        session.setMode(.fullRecipe)
    }

    func moveNext() {
        session.moveNext()
    }

    func movePrevious() {
        session.movePrevious()
    }

    func selectStep(at index: Int) {
        while session.currentStepIndex < index {
            let previousIndex = session.currentStepIndex
            session.moveNext()
            if session.currentStepIndex == previousIndex {
                break
            }
        }
        while session.currentStepIndex > index {
            let previousIndex = session.currentStepIndex
            session.movePrevious()
            if session.currentStepIndex == previousIndex {
                break
            }
        }
    }

    func toggleCompletedStep(_ stepID: UUID) {
        session.toggleCompletedStep(stepID)
    }

    func toggleCompletedIngredient(_ ingredientID: UUID) {
        session.toggleCompletedIngredient(ingredientID)
    }

    func isStepCompleted(_ stepID: UUID) -> Bool {
        session.completedStepIDs.contains(stepID)
    }

    func isIngredientCompleted(_ ingredientID: UUID) -> Bool {
        session.completedIngredientIDs.contains(ingredientID)
    }

    func timer(id: UUID) -> RecipeTimer? {
        timers[id]
    }

    func remainingSeconds(for timerID: UUID) -> Int? {
        timers[timerID]?.remainingSeconds(at: clock.now)
    }

    func timerPhase(for timerID: UUID) -> RecipeTimerPhase? {
        timers[timerID]?.phase(at: clock.now)
    }

    func startTimer(id timerID: UUID) async {
        guard var timer = timers[timerID],
              timer.start(at: clock.now) else {
            return
        }
        timers[timerID] = timer
        await notificationScheduler.schedule(
            timerID: timerID,
            label: timer.label,
            durationSeconds: timer.remainingSeconds(at: clock.now)
        )
        if timers[timerID]?.phase(at: clock.now) != .running {
            notificationScheduler.cancel(timerID: timerID)
        }
    }

    func pauseTimer(id timerID: UUID) {
        guard var timer = timers[timerID] else {
            return
        }
        timer.pause(at: clock.now)
        timers[timerID] = timer
        notificationScheduler.cancel(timerID: timerID)
    }

    func resetTimer(id timerID: UUID) {
        guard var timer = timers[timerID] else {
            return
        }
        timer.reset()
        timers[timerID] = timer
        notificationScheduler.cancel(timerID: timerID)
    }
}
