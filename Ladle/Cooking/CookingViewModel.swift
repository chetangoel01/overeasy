import Foundation
import LadleCore
import Observation

/// An ingredient the current step uses, as Focus Mode lists it.
struct StepIngredient: Identifiable {
    let ingredient: Ingredient
    /// The amount at the session's serving count, or `nil` when the recipe
    /// gives none.
    let amount: String?
    /// The other steps that use this ingredient, numbered from 1. An amount
    /// belongs to the whole recipe and is never split between steps, so a
    /// row with any of these has to say whose total it is showing.
    let otherStepNumbers: [Int]

    var id: UUID { ingredient.id }
}

@MainActor
@Observable
final class CookingViewModel: Identifiable {
    let id = UUID()
    let recipe: Recipe

    /// The serving count the recipe page was showing when cooking started.
    ///
    /// Cook mode is opened from the recipe page and built from what that page
    /// is displaying, so it cooks the amounts the cook was just reading. It is
    /// a snapshot rather than a shared object because the control is not on
    /// this screen: nothing here can change it, and the page underneath is
    /// covered while it is open.
    let scaling: RecipeScaling?
    private(set) var session: CookingSession
    private(set) var timers: [UUID: RecipeTimer]
    private(set) var keepsScreenAwake = false

    /// Whether Focus Mode lists the step's ingredients with their amounts or
    /// folds them to one line of names. It is the cook's for the session —
    /// from step to step, and through Full Recipe and back — and is not
    /// stored beyond it.
    var showsStepIngredientAmounts = true

    /// Called after anything a relaunch would have to restore. The store
    /// hangs snapshotting here rather than polling, so the written snapshot
    /// is never a step or a timer behind what the cook is looking at.
    @ObservationIgnored
    var sessionDidChange: () -> Void = {}

    @ObservationIgnored
    private let clock: CookingClock

    @ObservationIgnored
    private let notificationScheduler: TimerNotificationScheduling

    @ObservationIgnored
    private let screenAwakeController: ScreenAwakeController

    init(
        recipe: Recipe,
        scaling: RecipeScaling? = nil,
        clock: CookingClock = SystemCookingClock(),
        notificationScheduler: TimerNotificationScheduling =
            LocalTimerNotificationScheduler(),
        screenAwakeController: ScreenAwakeController =
            ScreenAwakeController()
    ) {
        self.recipe = recipe
        self.scaling = scaling
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

    /// Rebuilds the session a previous launch left behind. Steps and timers
    /// the recipe no longer has are dropped, so an edit between launches
    /// narrows the restored session rather than failing it.
    func restore(_ snapshot: CookingSessionSnapshot) {
        session = CookingSession(
            stepIDs: recipe.orderedSteps.map(\.id),
            currentStepIndex: snapshot.session.currentStepIndex,
            mode: snapshot.session.mode,
            completedStepIDs: snapshot.session.completedStepIDs,
            completedIngredientIDs: snapshot.session.completedIngredientIDs
        )
        let now = clock.now
        for timerSnapshot in snapshot.timers {
            guard let detectedTimer = timers[timerSnapshot.timerID]?
                .detectedTimer else { continue }
            timers[timerSnapshot.timerID] = RecipeTimer(
                detectedTimer,
                snapshot: timerSnapshot,
                at: now
            )
        }
    }

    var snapshot: CookingSessionSnapshot {
        CookingSessionSnapshot(
            recipeID: recipe.id,
            baseServings: scaling?.baseServings,
            servings: scaling?.servings,
            session: session,
            timers: recipe.orderedSteps
                .flatMap(\.timers)
                .compactMap { timers[$0.id]?.snapshot }
        )
    }

    var mode: CookingMode {
        session.mode
    }

    /// The factor every ingredient row on this screen is rendered through.
    var multiplier: Decimal? {
        scaling?.multiplier
    }

    /// The line under the title on a scaled session, and `nil` when the
    /// recipe is being cooked as written.
    var scaledYieldText: String? {
        guard let scaling, scaling.isScaled else { return nil }
        return scaling.chosenYieldText
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

    var stepIngredients: [StepIngredient] {
        let steps = recipe.orderedSteps
        guard steps.indices.contains(currentStepIndex) else {
            return []
        }
        let ingredientIDs = Set(steps[currentStepIndex].ingredientIDs)
        return recipe.orderedIngredients
            .filter { ingredientIDs.contains($0.id) }
            .map { ingredient in
                StepIngredient(
                    ingredient: ingredient,
                    amount: ingredient.amountText(scaledBy: multiplier ?? 1),
                    otherStepNumbers: steps.indices
                        .filter {
                            $0 != currentStepIndex
                                && steps[$0].ingredientIDs
                                    .contains(ingredient.id)
                        }
                        .map { $0 + 1 }
                )
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

    /// Whether a timer is still counting down, which is what makes replacing
    /// this session something to ask about. Read from the derived phase: a
    /// stored `.running` whose deadline has passed is finished, and a
    /// finished timer is not worth a dialog.
    var hasRunningTimer: Bool {
        let now = clock.now
        return timers.values.contains { $0.phase(at: now) == .running }
    }

    /// The cook is done with this recipe: every step ticked off and nothing
    /// still counting down. A last step that sets a timer — "rest for ten
    /// minutes" — is ticked before that timer finishes, and ending the
    /// session there would cancel the very alert this change exists to keep.
    var isCompleted: Bool {
        !recipe.orderedSteps.isEmpty
            && recipe.orderedSteps.allSatisfy {
                session.completedStepIDs.contains($0.id)
            }
            && !hasRunningTimer
    }

    /// The timers this session has finished and the cook has not yet
    /// acknowledged, which is what `TimerAlarm` sounds for.
    var finishedTimerIDs: Set<UUID> {
        let now = clock.now
        return Set(
            timers.values
                .filter { $0.phase(at: now) == .finished }
                .map(\.id)
        )
    }

    func beginCooking() {
        screenAwakeController.beginScope()
    }

    /// Leaving the cooking screen now gives up only the screen-awake scope.
    /// The session itself outlives the screen, so its pending timer alerts
    /// stay pending — see `endSession()`.
    func endCooking() {
        screenAwakeController.endScope()
        keepsScreenAwake = false
    }

    /// Ends the session for good. The one place a session's pending alerts
    /// are cancelled, so whatever else a session comes to own — a Live
    /// Activity next — is released here beside them.
    func endSession() {
        endCooking()
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
        sessionDidChange()
    }

    func exitFocusMode() {
        session.setMode(.fullRecipe)
        sessionDidChange()
    }

    func moveNext() {
        session.moveNext()
        sessionDidChange()
    }

    func movePrevious() {
        session.movePrevious()
        sessionDidChange()
    }

    /// Moves to a step by identity, which is how a tapped timer alert and
    /// an `overeasy://` link name the step they lead back to.
    func selectStep(id stepID: UUID) {
        guard let index = recipe.orderedSteps.firstIndex(
            where: { $0.id == stepID }
        ) else {
            return
        }
        selectStep(at: index)
    }

    func selectStep(at index: Int) {
        defer { sessionDidChange() }
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
        sessionDidChange()
    }

    func toggleCompletedIngredient(_ ingredientID: UUID) {
        session.toggleCompletedIngredient(ingredientID)
        sessionDidChange()
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
              let step = step(owning: timerID),
              timer.start(at: clock.now) else {
            return
        }
        timers[timerID] = timer
        sessionDidChange()
        await notificationScheduler.schedule(
            TimerNotification(
                timerID: timerID,
                label: timer.label,
                durationSeconds: timer.remainingSeconds(at: clock.now),
                recipeID: recipe.id,
                recipeTitle: recipe.title,
                stepID: step.id,
                stepNumber: step.number
            )
        )
        // A naturally finished countdown still needs its completion alert.
        // Only an explicit pause/reset makes this scheduling obsolete.
        if timers[timerID]?.phase != .running {
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
        sessionDidChange()
    }

    func resetTimer(id timerID: UUID) {
        guard var timer = timers[timerID] else {
            return
        }
        timer.reset()
        timers[timerID] = timer
        notificationScheduler.cancel(timerID: timerID)
        sessionDidChange()
    }

    private func step(
        owning timerID: UUID
    ) -> (id: UUID, number: Int)? {
        guard let index = recipe.orderedSteps.firstIndex(
            where: { $0.timers.contains { $0.id == timerID } }
        ) else {
            return nil
        }
        return (recipe.orderedSteps[index].id, index + 1)
    }
}
